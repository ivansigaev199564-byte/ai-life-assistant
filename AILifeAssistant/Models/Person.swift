import Foundation
import SwiftData

/// Человек, упомянутый в захвате.
///
/// Создаётся автоматически при разборе речи: «позвонить Мише» порождает
/// Person("Миша") и связывает с ним напоминание. Связь с системными
/// контактами появится на Этапе 5.
@Model
final class Person {
    @Attribute(.unique) var id: UUID

    /// Каноническое имя для отображения.
    var name: String

    /// Варианты написания и падежные формы: «Миша», «Мише», «Михаил».
    /// Нужны, чтобы разные упоминания вели к одной карточке.
    var aliases: [String]

    /// Нормализованное имя в нижнем регистре для быстрого поиска совпадений.
    var normalizedName: String

    /// Идентификатор записи в системных Контактах, Этап 5.
    var contactIdentifier: String?

    var createdAt: Date
    var updatedAt: Date

    /// Сколько раз человек упоминался. По этому счётчику сортируем подсказки.
    var mentionCount: Int

    private var syncStateRaw: String
    var remoteID: String?

    // Обратные стороны связей многие ко многим объявлены здесь,
    // поэтому в Note, TaskItem, Reminder и Expense указан inverse на эти свойства.
    var notes: [Note] = []
    var tasks: [TaskItem] = []
    var reminders: [Reminder] = []
    var expenses: [Expense] = []

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        contactIdentifier: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.normalizedName = Person.normalize(name)
        self.contactIdentifier = contactIdentifier
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.mentionCount = 0
        self.syncStateRaw = SyncState.pendingUpload.rawValue
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    var totalMentions: Int {
        notes.count + tasks.count + reminders.count + expenses.count
    }

    func registerMention() {
        mentionCount += 1
        updatedAt = .now
        syncState = .pendingUpload
    }

    /// Совпадает ли переданное упоминание с этим человеком.
    func matches(_ candidate: String) -> Bool {
        let normalized = Person.normalize(candidate)
        if normalized == normalizedName { return true }
        return aliases.contains { Person.normalize($0) == normalized }
    }

    /// Нормализация: нижний регистр, без диакритики и лишних пробелов.
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
