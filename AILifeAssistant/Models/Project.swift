import Foundation
import SwiftData

/// Проект или сфера жизни, к которой относится запись.
///
/// Работает как контейнер контекста: «по проекту Ольга» соберёт все заметки,
/// задачи и расходы вокруг одной темы.
@Model
final class Project {
    @Attribute(.unique) var id: UUID

    var name: String
    var normalizedName: String

    /// Синонимы названия, чтобы разные формулировки вели в один проект.
    var aliases: [String]

    var details: String

    /// Цвет карточки в шестнадцатеричном виде, например "#2F6BFF".
    var colorHex: String

    var isArchived: Bool

    var createdAt: Date
    var updatedAt: Date

    private var syncStateRaw: String
    var remoteID: String?

    var notes: [Note] = []
    var tasks: [TaskItem] = []
    var reminders: [Reminder] = []
    var expenses: [Expense] = []

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        details: String = "",
        colorHex: String = "#2F6BFF",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.normalizedName = Project.normalize(name)
        self.aliases = aliases
        self.details = details
        self.colorHex = colorHex
        self.isArchived = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.syncStateRaw = SyncState.pendingUpload.rawValue
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    var itemsCount: Int {
        notes.count + tasks.count + reminders.count + expenses.count
    }

    /// Незакрытые задачи и напоминания проекта.
    var openItemsCount: Int {
        tasks.filter { !$0.isCompleted }.count + reminders.filter { !$0.isCompleted }.count
    }

    func matches(_ candidate: String) -> Bool {
        let normalized = Project.normalize(candidate)
        if normalized == normalizedName { return true }
        return aliases.contains { Project.normalize($0) == normalized }
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
