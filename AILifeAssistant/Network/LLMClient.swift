import Foundation

/// Клиент облачного разбора.
///
/// Реализаций две: прямая к Anthropic и через собственную функцию-посредник.
/// Различаются только транспортом и авторизацией, контракт один.
protocol LLMClient: Sendable {

    /// Готов ли клиент выполнять запросы: включено ли облако, задан ли адрес.
    var isConfigured: Bool { get }

    /// Разбирает фразу и возвращает структуру, соответствующую схеме.
    func extractIntents(text: String, context: ParsingContext) async throws -> ParsedIntent
}

/// Разбор ответа модели в доменную структуру.
///
/// Вынесен отдельно, потому что одинаков для обоих клиентов: посредник
/// возвращает те же аргументы инструмента, что и Anthropic напрямую.
enum IntentResponseDecoder {

    /// Аргументы инструмента, как их описывает схема.
    struct Payload: Decodable {
        struct Item: Decodable {
            let kind: String
            let title: String
            let details: String?
            let dueDate: String?
            let priority: String?
            let amount: Double?
            let currencyCode: String?
            let category: String?
            let merchant: String?
            let people: [String]?
            let confidence: Double

            enum CodingKeys: String, CodingKey {
                case kind, title, details, amount, category, merchant, people, confidence
                case dueDate = "due_date"
                case currencyCode = "currency_code"
                case priority
            }
        }

        let items: [Item]
        let people: [String]?
        let projects: [String]?
        let language: String?
        let confidence: Double
    }

    /// Превращает аргументы инструмента в доменный результат.
    static func decode(
        _ payload: Payload,
        context: ParsingContext,
        sourceText: String,
        duration: TimeInterval
    ) throws -> ParsedIntent {
        let items = payload.items.compactMap { item -> ParsedItem? in
            guard let kind = ParsedItemKind(rawValue: item.kind.lowercased()) else { return nil }

            let amount: Decimal? = (item.amount ?? 0) > 0 ? Decimal(item.amount ?? 0) : nil
            let currency = item.currencyCode.flatMap { $0.isEmpty ? nil : $0.uppercased() }

            return ParsedItem(
                kind: kind,
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                details: item.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                dueDate: parseDate(item.dueDate, context: context),
                priority: item.priority.flatMap(Priority.init(rawValue:)) ?? .none,
                amount: amount,
                currencyCode: amount != nil ? (currency ?? context.defaultCurrencyCode) : nil,
                category: kind == .expense
                    ? (item.category.flatMap(ExpenseCategory.init(rawValue:)) ?? .other)
                    : nil,
                merchant: item.merchant?.isEmpty == false ? item.merchant : nil,
                people: item.people ?? [],
                confidence: min(1, max(0, item.confidence)),
                sourceText: sourceText
            )
        }

        guard !items.isEmpty else {
            throw ParsingError.invalidResponse("модель не вернула ни одной сущности")
        }

        return ParsedIntent(
            items: items,
            people: payload.people ?? [],
            projects: payload.projects ?? [],
            languageCode: payload.language ?? context.languageCode,
            confidence: min(1, max(0, payload.confidence)),
            engine: .cloud,
            duration: duration
        )
    }

    /// Модель возвращает дату строкой ISO 8601, но может опустить время.
    static func parseDate(_ value: String?, context: ParsingContext) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.timeZone = context.timeZone
        if let date = iso.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.timeZone = context.timeZone
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let dayOnly = DateFormatter()
        dayOnly.calendar = context.calendar
        dayOnly.timeZone = context.timeZone
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: value)
    }
}
