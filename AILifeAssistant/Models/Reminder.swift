import Foundation
import SwiftData

/// Напоминание с конкретной датой и временем.
///
/// В отличие от задачи, всегда имеет дату и порождает локальное уведомление,
/// а на Этапе 4 ещё и запись в Apple Reminders или событие календаря.
@Model
final class Reminder {
    @Attribute(.unique) var id: UUID

    var title: String
    var details: String

    /// Момент срабатывания. Обязателен по смыслу сущности.
    var fireDate: Date

    /// Правило повтора в текстовом виде ("daily", "weekly:mon,wed").
    /// Полноценный RRULE появится вместе с интеграцией EventKit.
    var recurrenceRule: String?

    var isCompleted: Bool
    var completedAt: Date?

    private var priorityRaw: String

    /// Идентификатор запланированного локального уведомления.
    /// Нужен, чтобы отменить его при удалении или переносе.
    var notificationIdentifier: String?

    /// Идентификатор записи в Apple Reminders или EKEvent, Этап 4.
    var externalIdentifier: String?

    var createdAt: Date
    var updatedAt: Date

    var confidence: Double
    var needsReview: Bool

    private var syncStateRaw: String
    var remoteID: String?
    var lastSyncedAt: Date?

    var source: CaptureItem?

    /// Идентификатор элемента разбора, породившего эту запись.
    /// По нему уточняющий проход находит созданную сущность и обновляет её,
    /// вместо того чтобы создать вторую такую же.
    var parsedItemID: UUID?

    @Relationship(deleteRule: .nullify, inverse: \Person.reminders)
    var people: [Person] = []

    @Relationship(deleteRule: .nullify, inverse: \Project.reminders)
    var projects: [Project] = []

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        fireDate: Date,
        recurrenceRule: String? = nil,
        priority: Priority = .none,
        confidence: Double = 1,
        needsReview: Bool = false,
        source: CaptureItem? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.fireDate = fireDate
        self.recurrenceRule = recurrenceRule
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

    var isOverdue: Bool {
        !isCompleted && fireDate < .now
    }

    func complete() {
        setCompleted(true)
    }

    /// Ставит или снимает отметку выполнения.
    ///
    /// Оба направления нужны в равной мере: по галочке промахиваются чаще,
    /// чем ошибаются в самом деле, и вернуть напоминание в работу должно быть
    /// так же просто, как закрыть.
    func setCompleted(_ completed: Bool) {
        isCompleted = completed
        completedAt = completed ? .now : nil
        updatedAt = .now
        syncState = .pendingUpload
    }

    func toggleCompletion() {
        setCompleted(!isCompleted)
    }
}
