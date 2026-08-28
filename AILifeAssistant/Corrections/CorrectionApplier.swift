import Foundation
import SwiftData

/// Применение голосового исправления к недавней записи.
///
/// Исправление относится к тому, что человек сказал только что, поэтому
/// цель ищется среди свежих записей. Окно намеренно короткое: фраза
/// «не сорок шесть, а шестьдесят четыре» через полчаса после исходной
/// записи почти наверняка означает что-то другое, и лучше создать новую
/// запись, чем молча переписать старую.
@MainActor
struct CorrectionApplier {

    /// Сколько времени исправление считается относящимся к последней записи.
    static let correctionWindow: TimeInterval = 180

    struct Outcome: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case amountChanged(from: Decimal, to: Decimal)
            case dateChanged(from: Date, to: Date)
            case titleChanged(from: String, to: String)
            case captureRemoved
            /// Подходящей записи не нашлось.
            case noTarget
        }

        let action: Action
        /// Понятное описание для баннера: пользователь должен сразу увидеть,
        /// что именно поняло приложение.
        let summary: String
        /// Запись, которую правили. Без неё откат не знает, к чему возвращаться.
        var captureID: UUID?
        /// Снимок удалённой записи. Отменить удаление больше нечем.
        var removed: RemovedCapture?
    }

    /// Всё, что нужно, чтобы вернуть удалённую запись.
    ///
    /// Производные сущности в снимок не входят: они восстанавливаются
    /// повторным разбором, и это надёжнее, чем копировать связи вручную.
    struct RemovedCapture: Equatable, Sendable {
        let id: UUID
        let text: String
        let createdAt: Date
        let source: CaptureSource
        let engine: SpeechEngineKind
        let languageCode: String?
        let recognitionConfidence: Double
        let audioDuration: TimeInterval
        let audioFileName: String?
    }

    /// Чем закончился откат.
    enum RevertResult: Equatable, Sendable {
        /// Запись восстановлена, её нужно разобрать заново.
        case restored(UUID)
        /// Значение возвращено к прежнему.
        case reverted
        case failed
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: Применение

    func apply(
        _ correction: CorrectionDetector.Correction,
        at referenceDate: Date = .now,
        excluding excludedID: UUID? = nil
    ) -> Outcome {
        guard let capture = recentCapture(before: referenceDate, excluding: excludedID) else {
            return Outcome(action: .noTarget, summary: "Нечего исправлять")
        }

        switch correction.target {
        case .cancellation:
            return remove(capture)

        case .amount(let newAmount):
            return changeAmount(of: capture, to: newAmount)

        case .date(let newDate):
            return changeDate(of: capture, to: newDate)

        case .title(let newTitle):
            return changeTitle(of: capture, to: newTitle)
        }
    }

    // MARK: Операции

    private func remove(_ capture: CaptureItem) -> Outcome {
        let snapshot = RemovedCapture(
            id: capture.id,
            text: capture.text,
            createdAt: capture.createdAt,
            source: capture.source,
            engine: capture.engine,
            languageCode: capture.languageCode,
            recognitionConfidence: capture.recognitionConfidence,
            audioDuration: capture.audioDuration,
            audioFileName: capture.audioFileName
        )

        // Аудиофайл остаётся на диске: удаление по голосу должно
        // отменяться целиком, вместе с записью голоса. Файл всё равно
        // уйдёт по сроку хранения записей.
        modelContext.delete(capture)
        save()

        return Outcome(
            action: .captureRemoved,
            summary: "Последняя запись удалена",
            captureID: snapshot.id,
            removed: snapshot
        )
    }

    /// Правит сумму последнего расхода.
    private func changeAmount(of capture: CaptureItem, to newAmount: Decimal) -> Outcome {
        guard let expense = capture.expenses.first else {
            return Outcome(action: .noTarget, summary: "В последней записи нет суммы")
        }

        let oldAmount = expense.amount
        expense.amount = newAmount
        expense.updatedAt = .now
        expense.syncState = .pendingUpload
        // Исправление рукой человека надёжнее любого разбора.
        expense.confidence = 1
        expense.needsReview = false
        // Пометка вместо правки текста. Раньше сумма подменялась прямо
        // в сказанном, подстрокой: во фразе «взял 2 по 46» замена сорока
        // шести задевала и соседнее число, а сама запись начинала врать
        // о том, что человек произнёс.
        expense.isUserEdited = true

        capture.updatedAt = .now
        save()

        return Outcome(
            action: .amountChanged(from: oldAmount, to: newAmount),
            summary: "Сумма исправлена на \(newAmount.formatted(.currency(code: expense.currencyCode)))",
            captureID: capture.id
        )
    }

    /// Правит дату напоминания или задачи.
    private func changeDate(of capture: CaptureItem, to newDate: Date) -> Outcome {
        if let reminder = capture.reminders.first {
            let oldDate = reminder.fireDate
            reminder.fireDate = newDate
            reminder.updatedAt = .now
            reminder.syncState = .pendingUpload
            reminder.confidence = 1
            reminder.needsReview = false
            reminder.isUserEdited = true
            save()

            return Outcome(
                action: .dateChanged(from: oldDate, to: newDate),
                summary: "Время исправлено на " + newDate.formatted(date: .abbreviated, time: .shortened),
                captureID: capture.id
            )
        }

        if let task = capture.tasks.first {
            let oldDate = task.dueDate ?? capture.createdAt
            task.dueDate = newDate
            task.updatedAt = .now
            task.syncState = .pendingUpload
            task.isUserEdited = true
            save()

            return Outcome(
                action: .dateChanged(from: oldDate, to: newDate),
                summary: "Срок исправлен на " + newDate.formatted(date: .abbreviated, time: .omitted),
                captureID: capture.id
            )
        }

        return Outcome(action: .noTarget, summary: "В последней записи нет даты")
    }

    /// Правит формулировку.
    private func changeTitle(of capture: CaptureItem, to newTitle: String) -> Outcome {
        let cleaned = FastPathParser.cleanTitle(newTitle)

        if let reminder = capture.reminders.first {
            let old = reminder.title
            reminder.title = cleaned
            reminder.updatedAt = .now
            reminder.syncState = .pendingUpload
            reminder.isUserEdited = true
            save()
            return Outcome(
                action: .titleChanged(from: old, to: cleaned),
                summary: "Текст исправлен",
                captureID: capture.id
            )
        }

        if let task = capture.tasks.first {
            let old = task.title
            task.title = cleaned
            task.updatedAt = .now
            task.syncState = .pendingUpload
            task.isUserEdited = true
            save()
            return Outcome(
                action: .titleChanged(from: old, to: cleaned),
                summary: "Текст исправлен",
                captureID: capture.id
            )
        }

        if let note = capture.notes.first {
            // Запоминаем именно тело, а не заголовок: по заголовку заметку
            // потом не восстановить, он производный.
            let old = note.body
            note.body = cleaned
            note.updatedAt = .now
            note.syncState = .pendingUpload
            note.isUserEdited = true
            save()
            return Outcome(
                action: .titleChanged(from: old, to: cleaned),
                summary: "Текст исправлен",
                captureID: capture.id
            )
        }

        return Outcome(action: .noTarget, summary: "Нечего исправлять")
    }

    // MARK: Откат

    /// Возвращает всё как было.
    ///
    /// Раньше кнопка «Отменить» на баннере исправления не делала ничего:
    /// баннер закрывался, будто откат сработал, а запись оставалась
    /// изменённой или удалённой. Хуже всего было с отменой по голосу,
    /// которая уносила запись вместе со всем, что из неё разобрано.
    @discardableResult
    func revert(_ outcome: Outcome) -> RevertResult {
        switch outcome.action {
        case .captureRemoved:
            guard let snapshot = outcome.removed else { return .failed }
            return restore(snapshot)

        case .amountChanged(let from, _):
            guard let capture = capture(withID: outcome.captureID),
                  let expense = capture.expenses.first
            else { return .failed }

            expense.amount = from
            expense.updatedAt = .now
            expense.syncState = .pendingUpload
            expense.isUserEdited = false

            capture.updatedAt = .now
            save()
            return .reverted

        case .dateChanged(let from, _):
            guard let capture = capture(withID: outcome.captureID) else { return .failed }

            if let reminder = capture.reminders.first {
                reminder.fireDate = from
                reminder.updatedAt = .now
                reminder.syncState = .pendingUpload
            } else if let task = capture.tasks.first {
                task.dueDate = from
                task.updatedAt = .now
                task.syncState = .pendingUpload
            } else {
                return .failed
            }

            save()
            return .reverted

        case .titleChanged(let from, _):
            guard let capture = capture(withID: outcome.captureID) else { return .failed }

            if let reminder = capture.reminders.first {
                reminder.title = from
                reminder.updatedAt = .now
                reminder.syncState = .pendingUpload
            } else if let task = capture.tasks.first {
                task.title = from
                task.updatedAt = .now
                task.syncState = .pendingUpload
            } else if let note = capture.notes.first {
                note.body = from
                note.updatedAt = .now
                note.syncState = .pendingUpload
            } else {
                return .failed
            }

            save()
            return .reverted

        case .noTarget:
            return .failed
        }
    }

    /// Возвращает удалённую запись на место.
    ///
    /// Производные сущности не восстанавливаются копированием: запись
    /// возвращается в состояние «ждёт разбора», и заметки, задачи,
    /// напоминания и расходы создаёт заново обычный конвейер.
    private func restore(_ snapshot: RemovedCapture) -> RevertResult {
        let capture = CaptureItem(
            id: snapshot.id,
            text: snapshot.text,
            status: .pending,
            source: snapshot.source,
            engine: snapshot.engine,
            languageCode: snapshot.languageCode,
            recognitionConfidence: snapshot.recognitionConfidence,
            audioDuration: snapshot.audioDuration,
            audioFileName: snapshot.audioFileName,
            createdAt: snapshot.createdAt
        )

        modelContext.insert(capture)
        save()

        return .restored(snapshot.id)
    }

    // MARK: Поиск цели

    /// Последняя запись в пределах окна исправления, строго раньше опорного
    /// момента.
    ///
    /// Строгость здесь принципиальна. Фраза-исправление к этому моменту уже
    /// сохранена как захват и является самой свежей записью, поэтому раньше
    /// «отмени последнюю запись» удаляло само себя: расход оставался на месте,
    /// а баннер сообщал, что запись удалена.
    func recentCapture(
        before referenceDate: Date = .now,
        excluding excludedID: UUID? = nil
    ) -> CaptureItem? {
        let cutoff = referenceDate.addingTimeInterval(-Self.correctionWindow)

        var descriptor = FetchDescriptor<CaptureItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 6

        let recent = (try? modelContext.fetch(descriptor)) ?? []
        return recent.first { candidate in
            candidate.id != excludedID
                && candidate.createdAt < referenceDate
                && candidate.createdAt >= cutoff
        }
    }

    private func capture(withID id: UUID?) -> CaptureItem? {
        guard let id else { return nil }

        var descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Исправление не сохранено: \(error.localizedDescription)")
        }
    }
}
