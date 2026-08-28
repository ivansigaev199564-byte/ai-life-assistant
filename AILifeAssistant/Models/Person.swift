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
        if Person.isSameName(candidate, name) { return true }
        return aliases.contains { Person.isSameName(candidate, $0) }
    }

    /// Одно ли это имя в разных падежах.
    ///
    /// Русская речь склоняет имена: «Мише», «Мишу», «Мишей» это тот же
    /// Миша. Точное сравнение завело бы четыре карточки на одного человека.
    /// Падеж меняет окончание, поэтому сравниваем основу без последней буквы.
    ///
    /// Короткие имена не сопоставляются: у «Ани» и «Ане» основа всего
    /// из двух букв, и на такой длине легко склеить разных людей.
    /// Лишняя карточка это меньшее зло, чем перепутанные люди.
    static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)

        if left == right { return true }

        // Сначала словарь: он знает, что «Даня» и «Дана» разные люди,
        // хотя расходятся той же гласной, что «Миша» и «Мише». А ещё он
        // честно говорит, что «Дане» может быть и тем, и другим.
        if let known = RussianNames.areSamePerson(left, right) {
            return known
        }

        // Сравнение по «первым N минус одна букве» склеивало разных людей:
        // у «Марка» и «Мары» совпадали первые три буквы, и записи уходили
        // не туда. Теперь отбрасывается не последняя буква подряд, а именно
        // падежное окончание.
        let leftStem = stem(of: left)
        let rightStem = stem(of: right)

        guard leftStem.count >= 3, rightStem.count >= 3 else { return false }
        return leftStem == rightStem
    }

    /// Основа имени без падежного окончания.
    ///
    /// Полностью различить имена без словаря нельзя: «Даня» и «Дана»
    /// отличаются той же гласной, что «Миша» и «Мише». Здесь выбран
    /// разбор в пользу объединения падежей, потому что человек, увидевший
    /// две карточки одного знакомого, объединит их руками, а вот незамеченное
    /// расщепление истории заметить нечем.
    private static let caseEndings = ["ою", "ей", "ой", "ом", "ем", "ю", "я", "е", "у", "ы", "и", "а"]

    static func stem(of name: String) -> String {
        var result = name

        for ending in caseEndings where result.count > ending.count + 2 && result.hasSuffix(ending) {
            result = String(result.dropLast(ending.count))
            break
        }

        // Мягкий знак на конце основы к делу не относится: «Игорь»
        // и «Игорю» это один человек.
        if result.hasSuffix("ь") { result = String(result.dropLast()) }

        return result
    }

    /// Нормализация: нижний регистр, без диакритики и лишних пробелов.
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
