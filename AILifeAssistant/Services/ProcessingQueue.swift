import Foundation
import Observation
import SwiftData

/// Очередь разбора захватов.
///
/// Захват сохраняется мгновенно и попадает сюда. Очередь прогоняет его через
/// каскад движков и материализует результат, обновляя те же записи по мере
/// уточнения. Ошибки не теряют текст: захват остаётся в базе со статусом,
/// и его можно переразобрать позже.
@MainActor
@Observable
final class ProcessingQueue {

    /// Сколько раз пробовать разобрать один захват, прежде чем оставить
    /// его в покое. Бесконечные повторы съедают батарею и трафик.
    static let maxAttempts = 3

    private(set) var isProcessing = false
    private(set) var pendingCount = 0
    private(set) var lastResult: EntityMaterializer.Result?

    /// Вызывается после материализации: синхронизация узнаёт, что у захвата
    /// появились или изменились производные сущности.
    var onEntitiesMaterialized: ((CaptureItem) -> Void)?

    private let modelContext: ModelContext
    private let pipeline: ParsingPipeline
    private let materializer: EntityMaterializer

    /// Идентификаторы захватов в работе: защита от повторного запуска
    /// разбора одного и того же захвата из разных мест.
    private var inFlight = Set<UUID>()

    init(
        modelContext: ModelContext,
        pipeline: ParsingPipeline
    ) {
        self.modelContext = modelContext
        self.pipeline = pipeline
        self.materializer = EntityMaterializer(modelContext: modelContext)
    }

    // MARK: Публичные операции

    /// Ставит захват в обработку. Вызывается сразу после сохранения записи.
    ///
    /// В задачу уходит идентификатор, а не сам объект: разбор занимает
    /// секунды, и за это время запись может быть удалена пользователем
    /// или контекст пересоздан. Обращение к уничтоженному объекту SwiftData
    /// роняет приложение без возможности перехвата.
    func enqueue(_ capture: CaptureItem) {
        let id = capture.id
        Task { [weak self] in
            await self?.process(captureID: id)
        }
    }

    /// Находит захват по идентификатору в текущем контексте.
    ///
    /// Возвращает nil, если запись успела исчезнуть: это штатная ситуация,
    /// а не ошибка.
    private func capture(withID id: UUID) -> CaptureItem? {
        let descriptor = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func process(captureID: UUID) async {
        guard let capture = capture(withID: captureID) else {
            Log.data.debug("Захват исчез до начала разбора")
            return
        }
        await process(capture)
    }

    /// Разбирает все захваты, ожидающие обработки.
    /// Вызывается при запуске приложения и после возврата сети.
    func processPending() async {
        let descriptor = FetchDescriptor<CaptureItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        guard let all = try? modelContext.fetch(descriptor) else { return }
        let pending = all.filter { capture in
            (capture.status == .pending || capture.status == .failed)
                && capture.processingAttempts < Self.maxAttempts
                && !capture.text.isEmpty
        }

        pendingCount = pending.count
        for capture in pending {
            await process(capture)
        }
        pendingCount = 0
    }

    /// Принудительный повтор: сбрасывает счётчик попыток.
    func retry(_ capture: CaptureItem) async {
        capture.processingAttempts = 0
        capture.failureReason = nil
        await process(capture)
    }

    // MARK: Обработка

    private func process(_ capture: CaptureItem) async {
        guard !inFlight.contains(capture.id) else { return }
        guard capture.processingAttempts < Self.maxAttempts else {
            Log.data.notice("Захват исчерпал попытки разбора: \(capture.id.uuidString, privacy: .public)")
            return
        }
        guard !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            capture.markFailed("Пустой текст")
            return
        }

        inFlight.insert(capture.id)
        isProcessing = true
        capture.markProcessing()

        defer {
            inFlight.remove(capture.id)
            isProcessing = !inFlight.isEmpty
        }

        let context = makeContext(for: capture)

        do {
            let outcome = try await pipeline.run(
                text: capture.text,
                context: context,
                onPreliminary: { [weak self] preliminary in
                    // Предварительный разбор материализуем сразу: пользователь
                    // видит созданные записи, пока модели ещё думают. Запись
                    // ищем заново: за это время она могла быть удалена.
                    let id = capture.id
                    Task { @MainActor [weak self] in
                        guard let self, let current = self.capture(withID: id) else { return }
                        self.materializer.materialize(preliminary, for: current)
                    }
                }
            )

            // Итоговый разбор обновит те же записи по идентификаторам элементов.
            let result = materializer.materialize(outcome.final, for: capture)
            lastResult = result
            onEntitiesMaterialized?(capture)

            Log.data.notice("""
                Разбор завершён: создано \(result.created), обновлено \(result.updated), \
                на проверку \(result.flaggedForReview), движки \
                \(outcome.enginesUsed.map(\.rawValue).joined(separator: ", "), privacy: .public)
                """)
        } catch let error as ParsingError {
            handle(error, for: capture)
        } catch {
            handle(.invalidResponse(error.localizedDescription), for: capture)
        }
    }

    private func handle(_ error: ParsingError, for capture: CaptureItem) {
        Log.data.error("Разбор не удался: \(error.localizedDescription)")

        // Ошибку, которую есть смысл повторить, оставляем в очереди.
        // Остальные закрываем сразу, чтобы не жечь ресурсы впустую.
        if error.isRetryable, capture.processingAttempts < Self.maxAttempts {
            capture.status = .pending
            capture.failureReason = error.errorDescription
        } else {
            capture.markFailed(error.errorDescription ?? "Ошибка разбора")
        }

        try? modelContext.save()
    }

    // MARK: Контекст

    /// Собирает подсказки для движков: время захвата, язык, известные
    /// люди и проекты. Без этого «завтра» считается от момента разбора,
    /// а не от момента, когда фраза была сказана.
    private func makeContext(for capture: CaptureItem) -> ParsingContext {
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []

        return ParsingContext(
            referenceDate: capture.createdAt,
            timeZone: .current,
            languageCode: capture.languageCode,
            knownPeople: people.map(\.name),
            knownProjects: projects.filter { !$0.isArchived }.map(\.name)
        )
    }
}
