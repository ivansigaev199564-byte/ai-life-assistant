import Foundation

/// Извлечение даты и времени из фразы.
///
/// Порядок разбора важен: сначала относительные конструкции («через час»),
/// затем именованные дни («завтра», «в пятницу»), затем части суток
/// («вечером») и только в конце NSDataDetector с явными датами.
/// Обратный порядок ломается на «завтра в девять»: детектор увидит «девять»
/// как время сегодня и потеряет «завтра».
enum DateExtractor {

    struct Result: Equatable, Sendable {
        let date: Date
        /// Было ли в фразе конкретное время. Если нет, вызывающая сторона
        /// сама решает, ставить ли время по умолчанию.
        let hasExplicitTime: Bool
        let matchedText: String
    }

    /// Время по умолчанию для дня без указанного часа.
    static let defaultHour = 9

    private static let partsOfDay: [(markers: [String], hour: Int)] = [
        (["утром", "с утра", "утро", "morning", "in the morning"], 9),
        (["днем", "в обед", "afternoon", "at noon", "noon"], 14),
        (["вечером", "вечер", "evening", "tonight", "in the evening"], 19),
        (["ночью", "ночь", "night", "at night"], 22)
    ]

    private static let weekdayNames: [(markers: [String], weekday: Int)] = [
        (["понедельник", "monday"], 2),
        (["вторник", "tuesday"], 3),
        (["сред", "wednesday"], 4),
        (["четверг", "thursday"], 5),
        (["пятниц", "friday"], 6),
        (["суббот", "saturday"], 7),
        (["воскресень", "sunday"], 1)
    ]

    // MARK: Точка входа

    static func extract(from text: String, context: ParsingContext) -> Result? {
        let normalized = IntentKeywords.normalize(text)

        if let relative = extractRelative(from: normalized, context: context) {
            return relative
        }
        if let named = extractNamedDay(from: normalized, context: context) {
            return named
        }
        if let weekday = extractWeekday(from: normalized, context: context) {
            return weekday
        }
        if let partOfDay = extractPartOfDay(from: normalized, context: context) {
            return partOfDay
        }
        return extractWithDetector(from: text, context: context)
    }

    // MARK: Относительное время

    /// «через час», «через 20 минут», «через 3 дня», «in 2 hours».
    private static func extractRelative(from text: String, context: ParsingContext) -> Result? {
        let pattern = "(через|in)\s+(\d+|полчаса|пол часа|час|день|неделю|a|an)?\s*"
            + "(секунд\w*|минут\w*|час\w*|дн\w*|день|недел\w*|месяц\w*|"
            + "seconds?|minutes?|hours?|days?|weeks?|months?)?"

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) else { return nil }

        let quantityRaw = match.range(at: 2).location == NSNotFound
            ? ""
            : nsText.substring(with: match.range(at: 2))
        let unitRaw = match.range(at: 3).location == NSNotFound
            ? ""
            : nsText.substring(with: match.range(at: 3))

        // «через полчаса» единственный случай, где количество и единица слиты.
        if quantityRaw.hasPrefix("пол") {
            let date = context.referenceDate.addingTimeInterval(30 * 60)
            return Result(
                date: date,
                hasExplicitTime: true,
                matchedText: nsText.substring(with: match.range)
            )
        }

        let quantity: Int
        if let parsed = Int(quantityRaw) {
            quantity = parsed
        } else if quantityRaw.isEmpty || quantityRaw == "a" || quantityRaw == "an" {
            quantity = 1
        } else {
            // «через час», «через день»: количество опущено, единица в этом же слове.
            quantity = 1
        }

        let unit = unitRaw.isEmpty ? quantityRaw : unitRaw
        guard let component = calendarComponent(for: unit) else { return nil }

        guard let date = context.calendar.date(
            byAdding: component,
            value: quantity,
            to: context.referenceDate
        ) else { return nil }

        // Для суток и крупнее конкретного времени в фразе нет.
        let isTimeUnit = component == .second || component == .minute || component == .hour
        return Result(
            date: date,
            hasExplicitTime: isTimeUnit,
            matchedText: nsText.substring(with: match.range)
        )
    }

    private static func calendarComponent(for unit: String) -> Calendar.Component? {
        switch true {
        case unit.hasPrefix("секунд"), unit.hasPrefix("second"):
            return .second
        case unit.hasPrefix("минут"), unit.hasPrefix("minute"):
            return .minute
        case unit.hasPrefix("час"), unit.hasPrefix("hour"):
            return .hour
        case unit.hasPrefix("дн"), unit.hasPrefix("день"), unit.hasPrefix("day"):
            return .day
        case unit.hasPrefix("недел"), unit.hasPrefix("week"):
            return .weekOfYear
        case unit.hasPrefix("месяц"), unit.hasPrefix("month"):
            return .month
        default:
            return nil
        }
    }

    // MARK: Именованные дни

    /// «сегодня», «завтра», «послезавтра» вместе с возможным временем.
    private static func extractNamedDay(from text: String, context: ParsingContext) -> Result? {
        let offsets: [(markers: [String], days: Int)] = [
            (["послезавтра", "day after tomorrow"], 2),
            (["завтра", "tomorrow"], 1),
            (["сегодня", "today"], 0)
        ]

        for entry in offsets {
            guard let marker = entry.markers.first(where: { text.contains($0) }) else { continue }
            guard let base = context.calendar.date(
                byAdding: .day,
                value: entry.days,
                to: context.referenceDate
            ) else { continue }

            let time = extractTimeOfDay(from: text, context: context)
            let date = applyTime(time, to: base, context: context)

            return Result(
                date: date,
                hasExplicitTime: time != nil,
                matchedText: marker
            )
        }
        return nil
    }

    // MARK: Дни недели

    /// «в пятницу», «в следующий понедельник», «on friday».
    private static func extractWeekday(from text: String, context: ParsingContext) -> Result? {
        guard let entry = weekdayNames.first(where: { names in
            names.markers.contains { text.contains($0) }
        }) else { return nil }

        let wantsNextWeek = text.contains("следующ") || text.contains("next")
        let calendar = context.calendar

        var components = DateComponents()
        components.weekday = entry.weekday

        // Ближайший такой день недели строго в будущем.
        guard var date = calendar.nextDate(
            after: context.referenceDate,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) else { return nil }

        if wantsNextWeek {
            date = calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        }

        let time = extractTimeOfDay(from: text, context: context)
        let result = applyTime(time, to: date, context: context)

        let marker = entry.markers.first { text.contains($0) } ?? ""
        return Result(date: result, hasExplicitTime: time != nil, matchedText: marker)
    }

    // MARK: Части суток

    /// «вечером», «утром» без указания дня: относим к сегодняшнему дню,
    /// а если время уже прошло, к завтрашнему.
    private static func extractPartOfDay(from text: String, context: ParsingContext) -> Result? {
        guard let entry = partsOfDay.first(where: { part in
            part.markers.contains { text.contains($0) }
        }) else { return nil }

        let calendar = context.calendar
        var date = calendar.date(
            bySettingHour: entry.hour,
            minute: 0,
            second: 0,
            of: context.referenceDate
        ) ?? context.referenceDate

        if date <= context.referenceDate {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }

        let marker = entry.markers.first { text.contains($0) } ?? ""
        return Result(date: date, hasExplicitTime: true, matchedText: marker)
    }

    // MARK: Время внутри фразы

    private struct TimeOfDay {
        let hour: Int
        let minute: Int
    }

    /// «в девять», «в 9», «в 15:30», «at 9 pm», «в половине десятого».
    private static func extractTimeOfDay(from text: String, context: ParsingContext) -> TimeOfDay? {
        // Числовое время с необязательными минутами и суффиксом am/pm.
        let numericPattern = "(?:в|at|к)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|утра|дня|вечера|ночи)?"
        if let regex = try? NSRegularExpression(pattern: numericPattern) {
            let nsText = text as NSString
            if let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
            ) {
                var hour = Int(nsText.substring(with: match.range(at: 1))) ?? 0
                let minute = match.range(at: 2).location == NSNotFound
                    ? 0
                    : Int(nsText.substring(with: match.range(at: 2))) ?? 0
                let suffix = match.range(at: 3).location == NSNotFound
                    ? ""
                    : nsText.substring(with: match.range(at: 3))

                hour = adjustHour(hour, suffix: suffix)
                if (0...23).contains(hour), (0...59).contains(minute) {
                    return TimeOfDay(hour: hour, minute: minute)
                }
            }
        }

        // Время числительным словом: «в девять», «в половине десятого».
        return extractSpelledTime(from: text)
    }

    /// Приводит час к 24-часовому виду по суффиксу.
    private static func adjustHour(_ hour: Int, suffix: String) -> Int {
        switch suffix {
        case "pm", "вечера":
            return hour < 12 ? hour + 12 : hour
        case "ночи":
            return hour == 12 ? 0 : (hour >= 10 ? hour : hour)
        case "дня":
            return hour < 12 ? hour + 12 : hour
        case "am", "утра":
            return hour == 12 ? 0 : hour
        default:
            return hour
        }
    }

    private static let spelledHours: [String: Int] = [
        "час": 13, "два": 14, "три": 15, "четыре": 16, "пять": 17,
        "шесть": 18, "семь": 19, "восемь": 20, "девять": 9, "десять": 10,
        "одиннадцать": 11, "двенадцать": 12,
        "one": 13, "two": 14, "three": 15, "four": 16, "five": 17,
        "six": 18, "seven": 19, "eight": 20, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12
    ]

    /// «в девять», «at nine». Час без уточнения трактуем по здравому смыслу:
    /// девять это утро, а три это день, потому что в три ночи не назначают дел.
    private static func extractSpelledTime(from text: String) -> TimeOfDay? {
        let pattern = "(?:в|at|к)\s+([\p{L}]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let word = nsText.substring(with: match.range(at: 1))
            guard var hour = spelledHours[word] else { continue }

            if text.contains("утра") || text.contains("am") {
                hour = hour > 12 ? hour - 12 : hour
            } else if text.contains("вечера") || text.contains("pm") {
                hour = hour < 12 ? hour + 12 : hour
            }
            return TimeOfDay(hour: hour, minute: 0)
        }
        return nil
    }

    // MARK: Явные даты

    /// Последний рубеж: системный детектор для «25 августа», «12.05», «в 18:00».
    private static func extractWithDetector(from text: String, context: ParsingContext) -> Result? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }

        let nsText = text as NSString
        guard let match = detector.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ), let date = match.date else { return nil }

        // Детектор возвращает время в текущем часовом поясе и не сообщает,
        // было ли оно в тексте. Считаем, что время указано, если в найденном
        // фрагменте есть двоеточие или маркер am/pm.
        let matchedText = nsText.substring(with: match.range)
        let lowered = matchedText.lowercased()
        let hasTime = lowered.contains(":") || lowered.contains("am") || lowered.contains("pm")

        return Result(date: date, hasExplicitTime: hasTime, matchedText: matchedText)
    }

    // MARK: Вспомогательное

    /// Ставит найденное время на дату. Если времени нет, оставляет день
    /// без изменений: решение о времени по умолчанию принимает вызывающий.
    private static func applyTime(
        _ time: TimeOfDay?,
        to date: Date,
        context: ParsingContext
    ) -> Date {
        guard let time else { return date }
        return context.calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: date
        ) ?? date
    }

    /// Приводит дату к времени по умолчанию, когда час в фразе не назван.
    /// Нужно напоминаниям: срабатывание в момент захвата бессмысленно.
    static func normalizedFireDate(from result: Result, context: ParsingContext) -> Date {
        guard !result.hasExplicitTime else { return result.date }

        let withDefaultHour = context.calendar.date(
            bySettingHour: defaultHour,
            minute: 0,
            second: 0,
            of: result.date
        ) ?? result.date

        // Если этот момент уже прошёл, переносим на следующий день:
        // напоминание в прошлом не сработает никогда.
        if withDefaultHour <= context.referenceDate {
            return context.calendar.date(byAdding: .day, value: 1, to: withDefaultHour)
                ?? withDefaultHour
        }
        return withDefaultHour
    }
}
