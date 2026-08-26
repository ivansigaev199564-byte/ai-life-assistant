import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// Структура, которую генерирует локальная модель.
///
/// Держим её плоской и на примитивах: чем проще схема, тем стабильнее
/// работает управляемая генерация на устройстве. Даты передаются строками
/// в ISO 8601, потому что модель уверенно печатает текст, а не типы.
@available(iOS 26.0, *)
@Generable
struct GeneratedIntent {

    @Guide(description: "Список действий, извлечённых из фразы пользователя")
    var items: [GeneratedItem]

    @Guide(description: "Имена людей, упомянутых во фразе")
    var people: [String]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedItem {

    @Guide(description: "Тип: note, task, reminder или expense")
    var kind: String

    @Guide(description: "Короткая суть действия без служебных слов")
    var title: String

    @Guide(description: "Уточнение или пустая строка")
    var details: String

    @Guide(description: "Дата и время в формате ISO 8601 или пустая строка")
    var dueDate: String

    @Guide(description: "Сумма расхода числом или 0, если это не трата")
    var amount: Double

    @Guide(description: "Код валюты из трёх букв или пустая строка")
    var currencyCode: String

    @Guide(description: "Категория расхода: food, transport, housing, health, entertainment, shopping, education, travel, services, other")
    var category: String

    @Guide(description: "Насколько уверенно определён смысл, от 0 до 1")
    var confidence: Double
}

/// Разбор фразы локальной моделью Apple Intelligence.
///
/// Работает без сети и без передачи данных наружу, поэтому идёт вторым
/// уровнем сразу после правил: если модель доступна, её результат точнее
/// регулярных выражений и почти всегда достаточен без облака.
@available(iOS 26.0, *)
struct FoundationModelsParser: IntentParsing {

    let engine: ParsingEngine = .foundationModels
    let requiresNetwork = false

    var isAvailable: Bool {
        get async {
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            case .unavailable(let reason):
                Log.data.notice("Локальная модель недоступна: \(String(describing: reason), privacy: .public)")
                return false
            @unknown default:
                return false
            }
        }
    }

    private static let instructions = """
        Ты разбираешь короткие голосовые заметки на осмысленные действия.
        Одна фраза может содержать несколько действий сразу: например, трату \
        и напоминание. Верни каждое действие отдельным элементом.

        Правила:
        - expense, если названа сумма денег;
        - reminder, если есть конкретное время или просьба напомнить;
        - task, если есть действие без точного времени;
        - note во всех остальных случаях.
        Заголовок пиши без служебных слов вроде «напомни» и «нужно».
        Даты приводи к ISO 8601 с часовым поясом пользователя.
        Не придумывай того, чего нет во фразе: пустое поле лучше выдумки.
        """

    func parse(text: String, context: ParsingContext) async throws -> ParsedIntent {
        let started = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParsingError.emptyInput }

        guard await isAvailable else {
            throw ParsingError.engineUnavailable(.foundationModels)
        }

        let session = LanguageModelSession(instructions: Self.instructions)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = context.timeZone
        let now = formatter.string(from: context.referenceDate)

        let prompt = """
            Текущий момент: \(now).
            Часовой пояс: \(context.timeZone.identifier).
            Валюта по умолчанию: \(context.defaultCurrencyCode).
            Известные люди: \(context.knownPeople.joined(separator: ", ")).

            Фраза: \(trimmed)
            """

        do {
            let response = try await session.respond(to: prompt, generating: GeneratedIntent.self)
            let generated = response.content

            let items = generated.items.compactMap {
                Self.convert($0, context: context, sourceText: trimmed)
            }

            guard !items.isEmpty else { throw ParsingError.invalidResponse("пустой список действий") }

            let confidence = items.reduce(into: 0.0) { $0 += $1.confidence } / Double(items.count)

            return ParsedIntent(
                items: items,
                people: generated.people,
                projects: FastPathParser.matchProjects(in: trimmed, context: context),
                languageCode: context.languageCode,
                confidence: confidence,
                engine: .foundationModels,
                duration: Date().timeIntervalSince(started)
            )
        } catch let error as ParsingError {
            throw error
        } catch {
            Log.data.error("Локальная модель не справилась: \(error.localizedDescription)")
            throw ParsingError.invalidResponse(error.localizedDescription)
        }
    }

    // MARK: Преобразование

    /// Переводит ответ модели в доменный тип, отбрасывая мусор.
    private static func convert(
        _ generated: GeneratedItem,
        context: ParsingContext,
        sourceText: String
    ) -> ParsedItem? {
        guard let kind = ParsedItemKind(rawValue: generated.kind.lowercased()) else { return nil }

        let date = parseDate(generated.dueDate, context: context)
        let amount: Decimal? = generated.amount > 0 ? Decimal(generated.amount) : nil
        let category = ExpenseCategory(rawValue: generated.category.lowercased())

        let title = generated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = generated.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !details.isEmpty || amount != nil else { return nil }

        return ParsedItem(
            kind: kind,
            title: title,
            details: details,
            dueDate: date,
            amount: amount,
            currencyCode: generated.currencyCode.isEmpty
                ? (amount != nil ? context.defaultCurrencyCode : nil)
                : generated.currencyCode.uppercased(),
            category: kind == .expense ? (category ?? .other) : nil,
            confidence: min(1, max(0, generated.confidence)),
            sourceText: sourceText
        )
    }

    /// Модель может вернуть дату в нескольких форматах, поэтому пробуем
    /// оба разбора: с дробными секундами и без.
    private static func parseDate(_ value: String, context: ParsingContext) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let plain = ISO8601DateFormatter()
        plain.timeZone = context.timeZone
        if let date = plain.date(from: trimmed) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.timeZone = context.timeZone
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        // Модель могла отдать только дату без времени.
        let dateOnly = DateFormatter()
        dateOnly.calendar = context.calendar
        dateOnly.timeZone = context.timeZone
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: trimmed)
    }
}

#endif
