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
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: Применение

    func apply(
        _ correction: CorrectionDetector.Correction,
        at referenceDate: Date = .now
    ) -> Outcome {
        guard let capture = recentCapture(before: referenceDate) else {
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
        if let fileName = capture.audioFileName {
            RecordingStore().delete(fileName: fileName)
        }

        modelContext.delete(capture)
        save()

        return Outcome(action: .captureRemoved, summary: "Последняя запись удалена")
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

        // Текст захвата тоже правим: иначе повторный разбор вернёт
        // старую сумму и перезатрёт исправление.
        capture.text = capture.text.replacingOccurrences(
            of: NSDecimalNumber(decimal: oldAmount).stringValue,
            with: NSDecimalNumber(decimal: newAmount).stringValue
        )
        capture.updatedAt = .now
        save()

        return Outcome(
            action: .amountChanged(from: oldAmount, to: newAmount),
            summary: "Сумма исправлена на \(newAmount.formatted(.currency(code: expense.currencyCode)))"
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
            save()

            return Outcome(
                action: .dateChanged(from: oldDate, to: newDate),
                summary: "Время исправлено на " + newDate.formatted(date: .abbreviated, time: .shortened)
            )
        }

        if let task = capture.tasks.first {
            let oldDate = task.dueDate ?? capture.createdAt
            task.dueDate = newDate
            task.updatedAt = .now
            task.syncState = .pendingUpload
            save()

            return Outcome(
                action: .dateChanged(from: oldDate, to: newDate),
                summary: "Срок исправлен на " + newDate.formatted(date: .abbreviated, time: .omitted)
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
            save()
            return Outcome(action: .titleChanged(from: old, to: cleaned), summary: "Текст исправлен")
        }

        if let task = capture.tasks.first {
            let old = task.title
            task.title = cleaned
            task.updatedAt = .now
            task.syncState = .pendingUpload
            save()
            return Outcome(action: .titleChanged(from: old, to: cleaned), summary: "Текст исправлен")
        }

        if let note = capture.notes.first {
            let old = note.displayTitle
            note.body = cleaned
            note.updatedAt = .now
            note.syncState = .pendingUpload
            save()
            return Outcome(action: .titleChanged(from: old, to: cleaned), summary: "Текст исправлен")
        }

        return Outcome(action: .noTarget, summary: "Нечего исправлять")
    }

    // MARK: Поиск цели

    /// Последняя запись в пределах окна исправления.
    ///
    /// Сама фраза-исправление в поиск не попадает: она ещё не сохранена
    /// как захват, конвейер спрашивает цель до создания записи.
    func recentCapture(before referenceDate: Date = .now) -> CaptureItem? {
        let cutoff = referenceDate.addingTimeInterval(-Self.correctionWindow)

        var descriptor = FetchDescriptor<CaptureItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5

        let recent = (try? modelContext.fetch(descriptor)) ?? []
        return recent.first { $0.createdAt >= cutoff }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Исправление не сохранено: \(error.localizedDescription)")
        }
    }
}
