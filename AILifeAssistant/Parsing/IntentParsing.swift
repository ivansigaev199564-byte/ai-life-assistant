import Foundation

/// Единый интерфейс движков разбора смысла.
///
/// За ним живут три реализации: быстрый локальный парсер на правилах,
/// локальная модель Apple Intelligence и облачная модель со строгой схемой.
/// Конвейер вызывает их каскадом и сливает результаты.
protocol IntentParsing: Sendable {

    /// Какой движок стоит за реализацией.
    var engine: ParsingEngine { get }

    /// Доступен ли движок прямо сейчас: модель загружена, сеть есть,
    /// железо подходит. Конвейер спрашивает это до вызова.
    var isAvailable: Bool { get async }

    /// Требует ли движок сети. Офлайн такие движки пропускаются.
    var requiresNetwork: Bool { get }

    /// Разбирает текст захвата.
    /// - Parameters:
    ///   - text: распознанная фраза.
    ///   - context: подсказки, повышающие точность.
    func parse(text: String, context: ParsingContext) async throws -> ParsedIntent
}

/// Контекст, который помогает разбору быть точнее.
struct ParsingContext: Sendable {

    /// Момент захвата: от него считаются «завтра», «через час», «в пятницу».
    var referenceDate: Date

    /// Часовой пояс пользователя. Держим явно: напоминание на девять утра
    /// должно сработать по местному времени, а не по UTC.
    var timeZone: TimeZone

    /// Язык фразы, если он известен от распознавания речи.
    var languageCode: String?

    /// Известные люди и проекты: помогают связать «Мише» с существующей
    /// карточкой, а не создавать дубль.
    var knownPeople: [String]
    var knownProjects: [String]

    /// Валюта по умолчанию, когда в фразе названа только сумма.
    var defaultCurrencyCode: String

    init(
        referenceDate: Date = .now,
        timeZone: TimeZone = .current,
        languageCode: String? = nil,
        knownPeople: [String] = [],
        knownProjects: [String] = [],
        defaultCurrencyCode: String = Locale.current.currency?.identifier ?? "RUB"
    ) {
        self.referenceDate = referenceDate
        self.timeZone = timeZone
        self.languageCode = languageCode
        self.knownPeople = knownPeople
        self.knownProjects = knownProjects
        self.defaultCurrencyCode = defaultCurrencyCode
    }

    /// Календарь с учётом часового пояса контекста.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Неделя начинается с понедельника: «в пятницу» и «на выходных»
        // считаются от этого, иначе на воскресенье приходится сдвиг.
        calendar.firstWeekday = 2
        return calendar
    }

    /// Русский ли текст. Определяем по языку распознавания, а при его
    /// отсутствии по наличию кириллицы.
    func isRussian(_ text: String) -> Bool {
        if let languageCode, languageCode.hasPrefix("ru") { return true }
        if let languageCode, languageCode.hasPrefix("en") { return false }
        return text.range(of: #"\p{Cyrillic}"#, options: .regularExpression) != nil
    }
}

/// Ошибки разбора.
enum ParsingError: LocalizedError, Equatable {
    case engineUnavailable(ParsingEngine)
    case emptyInput
    case invalidResponse(String)
    case network(String)
    case rateLimited(retryAfter: TimeInterval?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let engine):
            return "Движок разбора недоступен: \(engine.rawValue)"
        case .emptyInput:
            return "Пустой текст, разбирать нечего"
        case .invalidResponse(let details):
            return "Модель вернула неожиданный ответ: \(details)"
        case .network(let details):
            return "Сетевая ошибка: \(details)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Слишком много запросов, повтор через \(Int(retryAfter)) с"
            }
            return "Слишком много запросов"
        case .cancelled:
            return "Разбор отменён"
        }
    }

    /// Есть ли смысл повторять попытку.
    var isRetryable: Bool {
        switch self {
        case .network, .rateLimited: return true
        case .engineUnavailable, .emptyInput, .invalidResponse, .cancelled: return false
        }
    }
}
