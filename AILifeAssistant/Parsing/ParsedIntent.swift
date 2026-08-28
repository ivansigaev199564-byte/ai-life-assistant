import Foundation

/// Тип сущности, которую предлагает создать разбор.
enum ParsedItemKind: String, Codable, CaseIterable, Sendable {
    case note
    case task
    case reminder
    case expense
}

/// Одна сущность, извлечённая из фразы.
///
/// Намеренно плоская: поля всех четырёх типов лежат рядом и заполняются
/// по мере надобности. Так проще описывать схему для модели и сливать
/// результаты разных движков.
struct ParsedItem: Codable, Sendable, Equatable, Identifiable {

    var id: UUID
    var kind: ParsedItemKind

    /// Короткая формулировка: заголовок задачи, суть напоминания, описание расхода.
    var title: String
    var details: String

    // MARK: Время

    /// Для напоминания это момент срабатывания, для задачи мягкий срок.
    var dueDate: Date?
    var priority: Priority

    /// Правило повтора: "daily", "weekly:mon", "monthly".
    ///
    /// Раньше оно оставалось только текстом в описании, и «каждый день
    /// в полдевятого» приходило ровно один раз.
    var recurrenceRule: String?

    // MARK: Деньги

    var amount: Decimal?
    var currencyCode: String?
    var category: ExpenseCategory?
    var merchant: String?

    // MARK: Контекст

    var people: [String]
    var projects: [String]
    var tags: [String]

    /// Уверенность разбора именно этой сущности, 0...1.
    var confidence: Double

    /// Фрагмент исходной фразы, из которого получена сущность.
    /// Нужен для отладки и для экрана «что распозналось».
    var sourceText: String

    init(
        id: UUID = UUID(),
        kind: ParsedItemKind,
        title: String,
        details: String = "",
        dueDate: Date? = nil,
        priority: Priority = .none,
        recurrenceRule: String? = nil,
        amount: Decimal? = nil,
        currencyCode: String? = nil,
        category: ExpenseCategory? = nil,
        merchant: String? = nil,
        people: [String] = [],
        projects: [String] = [],
        tags: [String] = [],
        confidence: Double = 0.5,
        sourceText: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.dueDate = dueDate
        self.priority = priority
        self.recurrenceRule = recurrenceRule
        self.amount = amount
        self.currencyCode = currencyCode
        self.category = category
        self.merchant = merchant
        self.people = people
        self.projects = projects
        self.tags = tags
        self.confidence = confidence
        self.sourceText = sourceText
    }

    /// Пригодна ли сущность к созданию без участия пользователя.
    ///
    /// Порог 0.7 задан в ТЗ: ниже него запись превращается в заметку
    /// с пометкой на проверку вместо неверно созданной задачи.
    var isConfident: Bool { confidence >= 0.7 }

    /// Минимальная осмысленность: пустую сущность создавать нельзя.
    var isValid: Bool {
        switch kind {
        case .expense:
            guard let amount else { return false }
            return amount > 0
        case .reminder:
            return dueDate != nil && !title.isEmpty
        case .task, .note:
            return !title.isEmpty || !details.isEmpty
        }
    }
}

/// Полный результат разбора одной фразы.
struct ParsedIntent: Codable, Sendable, Equatable {

    /// Одна фраза может дать несколько сущностей: в этом суть мульти-интента.
    var items: [ParsedItem]

    /// Люди и проекты, упомянутые во всей фразе целиком.
    var people: [String]
    var projects: [String]

    var languageCode: String?

    /// Общая уверенность разбора.
    var confidence: Double

    var engine: ParsingEngine

    /// Сколько заняла обработка, для диагностики скорости.
    var duration: TimeInterval

    init(
        items: [ParsedItem] = [],
        people: [String] = [],
        projects: [String] = [],
        languageCode: String? = nil,
        confidence: Double = 0,
        engine: ParsingEngine = .fastPath,
        duration: TimeInterval = 0
    ) {
        self.items = items
        self.people = people
        self.projects = projects
        self.languageCode = languageCode
        self.confidence = confidence
        self.engine = engine
        self.duration = duration
    }

    static let empty = ParsedIntent()

    var isEmpty: Bool { items.isEmpty }

    /// Только те сущности, которые можно создавать без подтверждения.
    var confidentItems: [ParsedItem] {
        items.filter { $0.isConfident && $0.isValid }
    }

    /// Сущности, которые лучше показать пользователю на проверку.
    var uncertainItems: [ParsedItem] {
        items.filter { !$0.isConfident || !$0.isValid }
    }
}
