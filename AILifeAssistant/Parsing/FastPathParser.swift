import Foundation

/// Локальный разбор на правилах: регулярные выражения, словари маркеров
/// и NaturalLanguage.
///
/// Задача этого движка не понять всё, а мгновенно понять типичное. Он
/// работает офлайн за единицы миллисекунд, и именно его результат
/// пользователь видит сразу после того, как отпустил кнопку. Всё сложное
/// достаётся моделям, которые подключаются следом.
struct FastPathParser: IntentParsing {

    let engine: ParsingEngine = .fastPath
    var isAvailable: Bool { get async { true } }
    let requiresNetwork = false

    /// Союзы, по которым фраза делится на отдельные намерения.
    /// «Купил кофе за 300 и напомни позвонить маме» это два действия.
    private static let separators = [
        " и напомни", " и не забыть", " и нужно", " и надо", " а также",
        " плюс ещё", " плюс ", " потом ", " ещё нужно", " ещё надо",
        " and remind", " and i need", " also ", " plus "
    ]

    func parse(text: String, context: ParsingContext) async throws -> ParsedIntent {
        let started = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParsingError.emptyInput }

        let segments = Self.split(trimmed)
        var items = segments.compactMap { Self.parseSegment($0, context: context) }

        // Фраза не распалась ни на одно намерение: сохраняем её как заметку,
        // чтобы сказанное не потерялось.
        if items.isEmpty {
            items = [Self.makeNote(from: trimmed, context: context)]
        }

        let people = PersonExtractor.extract(from: trimmed, context: context)
        let projects = Self.matchProjects(in: trimmed, context: context)

        // Людей и проекты, найденных по всей фразе, раздаём тем сущностям,
        // у которых своих упоминаний не нашлось.
        items = items.map { item in
            var updated = item
            if updated.people.isEmpty { updated.people = people }
            if updated.projects.isEmpty { updated.projects = projects }
            return updated
        }

        let confidence = items.isEmpty
            ? 0
            : items.reduce(into: 0.0) { $0 += $1.confidence } / Double(items.count)

        return ParsedIntent(
            items: items,
            people: people,
            projects: projects,
            languageCode: context.languageCode,
            confidence: confidence,
            engine: .fastPath,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: Разбиение на намерения

    /// Делит фразу по союзам, но только там, где вторая часть похожа
    /// на самостоятельное действие. Иначе «кофе и чай за 300» развалится
    /// на два бессмысленных куска.
    static func split(_ text: String) -> [String] {
        let normalized = IntentKeywords.normalize(text)
        var cutPoints: [Int] = []

        for separator in separators {
            var searchStart = normalized.startIndex
            while let range = normalized.range(
                of: separator,
                options: [],
                range: searchStart..<normalized.endIndex
            ) {
                cutPoints.append(normalized.distance(from: normalized.startIndex, to: range.lowerBound))
                searchStart = range.upperBound
                if searchStart >= normalized.endIndex { break }
            }
        }

        guard !cutPoints.isEmpty else { return [text] }

        let sorted = cutPoints.sorted()
        var segments: [String] = []
        var previous = text.startIndex

        for offset in sorted {
            guard let index = text.index(
                text.startIndex,
                offsetBy: offset,
                limitedBy: text.endIndex
            ), index > previous else { continue }

            let piece = String(text[previous..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.count > 2 { segments.append(piece) }
            previous = index
        }

        let tail = String(text[previous...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 2 { segments.append(tail) }

        return segments.isEmpty ? [text] : segments
    }

    // MARK: Разбор одного намерения

    static func parseSegment(_ segment: String, context: ParsingContext) -> ParsedItem? {
        let cleaned = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return nil }

        let amount = AmountExtractor.extract(from: cleaned, defaultCurrency: context.defaultCurrencyCode)
        let date = DateExtractor.extract(from: cleaned, context: context)
        let people = PersonExtractor.extract(from: cleaned, context: context)

        let hasExpenseMarker = IntentKeywords.contains(cleaned, any: IntentKeywords.expense)
        let hasReminderMarker = IntentKeywords.contains(cleaned, any: IntentKeywords.reminder)
        let hasTaskMarker = IntentKeywords.contains(cleaned, any: IntentKeywords.task)
        let priority = IntentKeywords.priority(in: cleaned)

        // Порядок проверок важен. Просьба напомнить перебивает всё:
        // в «напомни в девять» число это время, а не сумма, и без этого
        // правила любая названная цифра превращала бы фразу в расход.
        if hasReminderMarker {
            return makeReminder(
                from: cleaned,
                date: date,
                people: people,
                priority: priority,
                hasMarker: true,
                context: context
            )
        }

        // Трата: либо валюта названа вслух, либо есть глагол покупки.
        // Одного числа недостаточно, оно может быть чем угодно.
        if let amount, hasExpenseMarker || amount.hasExplicitCurrency {
            return makeExpense(
                from: cleaned,
                amount: amount,
                date: date,
                people: people,
                hasMarker: hasExpenseMarker,
                context: context
            )
        }

        // Напоминание без слова «напомни»: спасает конкретное время.
        if date?.hasExplicitTime == true {
            return makeReminder(
                from: cleaned,
                date: date,
                people: people,
                priority: priority,
                hasMarker: false,
                context: context
            )
        }

        if hasTaskMarker || date != nil {
            return makeTask(
                from: cleaned,
                date: date,
                people: people,
                priority: priority,
                hasMarker: hasTaskMarker,
                context: context
            )
        }

        return makeNote(from: cleaned, context: context)
    }

    // MARK: Конструкторы сущностей

    private static func makeExpense(
        from text: String,
        amount: AmountExtractor.Result,
        date: DateExtractor.Result?,
        people: [String],
        hasMarker: Bool,
        context: ParsingContext
    ) -> ParsedItem {
        let category = IntentKeywords.expenseCategory(in: text) ?? .other

        // Уверенность складывается из сигналов: явный маркер траты,
        // названная валюта и узнанная категория.
        var confidence = 0.6
        if hasMarker { confidence += 0.2 }
        if amount.currencyCode != nil { confidence += 0.1 }
        if category != .other { confidence += 0.1 }

        return ParsedItem(
            kind: .expense,
            title: cleanTitle(text),
            details: "",
            dueDate: date?.date,
            amount: amount.amount,
            currencyCode: amount.currencyCode ?? context.defaultCurrencyCode,
            category: category,
            people: people,
            confidence: min(1, confidence),
            sourceText: text
        )
    }

    private static func makeReminder(
        from text: String,
        date: DateExtractor.Result?,
        people: [String],
        priority: Priority,
        hasMarker: Bool,
        context: ParsingContext
    ) -> ParsedItem {
        // Напоминание без времени бессмысленно: ставим утро ближайшего дня.
        let fireDate: Date
        if let date {
            fireDate = DateExtractor.normalizedFireDate(from: date, context: context)
        } else {
            let tomorrow = context.calendar.date(byAdding: .day, value: 1, to: context.referenceDate)
                ?? context.referenceDate
            fireDate = context.calendar.date(
                bySettingHour: DateExtractor.defaultHour,
                minute: 0,
                second: 0,
                of: tomorrow
            ) ?? tomorrow
        }

        var confidence = 0.5
        if hasMarker { confidence += 0.25 }
        if date != nil { confidence += 0.15 }
        if date?.hasExplicitTime == true { confidence += 0.1 }

        return ParsedItem(
            kind: .reminder,
            title: cleanTitle(text, removing: IntentKeywords.reminder + (date.map { [$0.matchedText] } ?? [])),
            dueDate: fireDate,
            priority: priority,
            people: people,
            confidence: min(1, confidence),
            sourceText: text
        )
    }

    private static func makeTask(
        from text: String,
        date: DateExtractor.Result?,
        people: [String],
        priority: Priority,
        hasMarker: Bool,
        context: ParsingContext
    ) -> ParsedItem {
        var confidence = 0.55
        if hasMarker { confidence += 0.2 }
        if date != nil { confidence += 0.1 }
        if priority != .none { confidence += 0.05 }

        return ParsedItem(
            kind: .task,
            title: cleanTitle(text, removing: IntentKeywords.task),
            dueDate: date?.date,
            priority: priority,
            people: people,
            confidence: min(1, confidence),
            sourceText: text
        )
    }

    static func makeNote(from text: String, context: ParsingContext) -> ParsedItem {
        // Заметке даём невысокую уверенность: это выбор по остаточному
        // принципу, и модель следующего уровня вполне может решить иначе.
        ParsedItem(
            kind: .note,
            title: "",
            details: text,
            people: PersonExtractor.extract(from: text, context: context),
            confidence: 0.5,
            sourceText: text
        )
    }

    // MARK: Заголовок

    /// Убирает служебные слова из заголовка: «напомни завтра позвонить маме»
    /// должно превратиться в «позвонить маме».
    static func cleanTitle(_ text: String, removing markers: [String] = []) -> String {
        var result = text

        for marker in markers where !marker.isEmpty {
            // Ищем без учёта регистра, но вырезаем из исходной строки,
            // чтобы не терять оригинальное написание остального текста.
            while let range = result.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.removeSubrange(range)
            }
        }

        result = result
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-—"))

        // Первая буква заглавная: так заголовок читается как заголовок.
        guard let first = result.first else { return text }
        return first.uppercased() + result.dropFirst()
    }

    // MARK: Проекты

    /// Ищет упоминания известных проектов. Новые проекты локальный движок
    /// не придумывает: это работа моделей, у правил нет для этого контекста.
    static func matchProjects(in text: String, context: ParsingContext) -> [String] {
        let normalized = IntentKeywords.normalize(text)
        return context.knownProjects.filter { project in
            let normalizedProject = IntentKeywords.normalize(project)
            guard normalizedProject.count >= 3 else { return false }
            return normalized.contains(normalizedProject)
        }
    }
}
