import Foundation
import Observation
import SwiftData

/// Отмена последнего действия.
///
/// Пять секунд из технического задания это не произвольное число, а время,
/// за которое человек успевает прочитать баннер и передумать. Дольше держать
/// нельзя: баннер перекрывает список и начинает раздражать; короче тоже,
/// не успеешь прочитать.
///
/// Отмена нужна именно голосовому вводу: пользователь не видит, что записал,
/// пока не отпустит кнопку, и первая же реакция на неверный разбор должна
/// быть в одно касание.
@MainActor
@Observable
final class UndoService {

    /// Сколько баннер остаётся на экране.
    static let window: TimeInterval = 5

    /// Что можно отменить.
    struct Action: Identifiable, Equatable {
        enum Kind: Equatable {
            case captureCreated(UUID)
            case correctionApplied(CorrectionApplier.Outcome.Action, captureID: UUID)
        }

        let id = UUID()
        let kind: Kind
        /// Что показать в баннере.
        let message: String
        let createdAt: Date
    }

    private(set) var pending: Action?

    private let modelContext: ModelContext
    private var dismissTask: Task<Void, Never>?

    /// Вызывается, когда действие отменено: интерфейс обновляет списки,
    /// а синхронизация узнаёт, что запись исчезла.
    var onUndone: ((Action) -> Void)?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: Регистрация

    /// Показывает баннер отмены для новой записи.
    func register(captureCreated capture: CaptureItem) {
        let summary = Self.summary(for: capture)
        present(Action(kind: .captureCreated(capture.id), message: summary, createdAt: .now))
    }

    /// Показывает баннер после применённого исправления.
    func register(correction outcome: CorrectionApplier.Outcome, captureID: UUID) {
        present(
            Action(
                kind: .correctionApplied(outcome.action, captureID: captureID),
                message: outcome.summary,
                createdAt: .now
            )
        )
    }

    private func present(_ action: Action) {
        dismissTask?.cancel()
        pending = action

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.window))
            guard !Task.isCancelled else { return }
            self?.pending = nil
        }
    }

    // MARK: Отмена

    /// Отменяет действие.
    func undo() {
        guard let action = pending else { return }

        dismissTask?.cancel()
        pending = nil

        switch action.kind {
        case .captureCreated(let id):
            undoCapture(id: id)

        case .correctionApplied:
            // Возврат исправления не реализуем: восстанавливать предыдущее
            // значение вслепую опаснее, чем оставить как есть. Пользователь
            // поправит вручную на экране записи, где видит и текст, и разбор.
            Log.ui.notice("Отмена исправления не поддерживается")
        }

        onUndone?(action)
    }

    /// Скрывает баннер, не отменяя действие.
    func dismiss() {
        dismissTask?.cancel()
        pending = nil
    }

    private func undoCapture(id: UUID) {
        let descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.id == id })

        guard let capture = try? modelContext.fetch(descriptor).first else { return }

        // Аудиофайл живёт вне базы, удаляется отдельно.
        if let fileName = capture.audioFileName {
            RecordingStore().delete(fileName: fileName)
        }

        modelContext.delete(capture)

        do {
            try modelContext.save()
            Log.ui.notice("Запись отменена пользователем")
        } catch {
            Log.data.error("Отмена записи не сохранилась: \(error.localizedDescription)")
        }
    }

    // MARK: Текст баннера

    /// Что показать в баннере.
    ///
    /// Пока разбор не закончился, показывается сам текст: человеку важно
    /// убедиться, что его услышали правильно. Когда сущности созданы,
    /// показывается результат, потому что он и есть смысл записи.
    private static func summary(for capture: CaptureItem) -> String {
        if capture.hasDerivedItems {
            var parts: [String] = []

            if let expense = capture.expenses.first {
                parts.append("расход " + expense.formattedAmount)
            }
            if let reminder = capture.reminders.first {
                parts.append("напоминание на " + reminder.fireDate.formatted(date: .omitted, time: .shortened))
            }
            if !capture.tasks.isEmpty {
                parts.append("задача")
            }
            if !capture.notes.isEmpty, parts.isEmpty {
                parts.append("заметка")
            }

            if !parts.isEmpty {
                return "Создано: " + parts.joined(separator: ", ")
            }
        }

        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Запись сохранена" : String(text.prefix(60))
    }
}
