import Foundation
import SwiftData

/// Задача без жёсткой привязки ко времени.
///
/// Имя `Task` занято Swift Concurrency, поэтому модель называется `TaskItem`.
/// Отличие от `Reminder`: у задачи может не быть даты, и она не создаёт
/// системное уведомление.
@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID

    var title: String
    var details: String

    /// Мягкий срок: «на этой неделе», «до пятницы». Может отсутствовать.
    var dueDate: Date?

    var isCompleted: Bool
    var completedAt: Date?

    private var priorityRaw: String

    var createdAt: Date
    var updatedAt: Date

    var confidence: Double
    var needsReview: Bool

    /// Значение поправил человек.
    ///
    /// Разбор не должен перезаписывать то, что пользователь исправил
    /// вручную или голосом: раньше правка суммы держалась только на том,
    /// что исправление переписывало текст записи подстрокой, а это могло
    /// задеть соседние числа в той же фразе.
    var isUserEdited: Bool = false


    private var syncStateRaw: String
    var remoteID: String?
    var lastSyncedAt: Date?

    /// Идентификатор в Apple Reminders, заполняется на Этапе 4.
    var externalReminderID: String?

    var source: CaptureItem?

    /// Идентификатор элемента разбора, породившего эту запись.
    /// По нему уточняющий проход находит созданную сущность и обновляет её,
    /// вместо того чтобы создать вторую такую же.
    var parsedItemID: UUID?

    @Relationship(deleteRule: .nullify, inverse: \Person.tasks)
    var people: [Person] = []

    @Relationship(deleteRule: .nullify, inverse: \Project.tasks)
    var projects: [Project] = []

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        dueDate: Date? = nil,
        priority: Priority = .none,
        confidence: Double = 1,
        needsReview: Bool = false,
        source: CaptureItem? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.dueDate = dueDate
        self.priorityRaw = priority.rawValue
        self.isCompleted = false
        self.confidence = confidence
        self.needsReview = needsReview
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.syncStateRaw = SyncState.pendingUpload.rawValue
        self.source = source
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .none }
        set {
            priorityRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    /// Срок прошёл, а задача не закрыта.
    var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < .now
    }

    func toggleCompletion() {
        setCompleted(!isCompleted)
    }

    /// Ставит или снимает отметку выполнения.
    ///
    /// Явное значение нужно там, где состояние приходит извне: из виджета,
    /// из системных Напоминаний, из синхронизации.
    func setCompleted(_ completed: Bool) {
        isCompleted = completed
        completedAt = completed ? .now : nil
        updatedAt = .now
        syncState = .pendingUpload
    }
}
