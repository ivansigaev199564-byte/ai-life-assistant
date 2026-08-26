import Foundation

/// Извлечение денежных сумм и валют из фразы.
///
/// Работает и с цифрами, и с числительными словами: распознавание речи
/// отдаёт то «300 рублей», то «триста рублей» в зависимости от движка
/// и языка, поэтому оба варианта обязаны разбираться одинаково.
enum AmountExtractor {

    struct Result: Equatable, Sendable {
        let amount: Decimal
        /// Код валюты по ISO 4217. Пусто, если названо только число.
        let currencyCode: String?
        /// Валюта названа в самой фразе, а не подставлена по умолчанию.
        ///
        /// Различие принципиальное: без него любое числительное в речи
        /// выглядит как трата, и «напомни в девять» превращается в расход
        /// на девять рублей.
        let hasExplicitCurrency: Bool
        /// Фрагмент текста, из которого взята сумма.
        let matchedText: String
    }

    // MARK: Валюты

    private static let currencyMarkers: [(code: String, markers: [String])] = [
        ("RUB", ["₽", "руб", "рубл", "rub", "ruble", "rouble"]),
        ("USD", ["$", "usd", "доллар", "долар", "бакс", "dollar", "buck"]),
        ("EUR", ["€", "eur", "евро", "euro"]),
        ("GBP", ["£", "gbp", "фунт", "pound"]),
        ("KZT", ["₸", "kzt", "тенге", "tenge"]),
        ("UAH", ["₴", "uah", "гривн", "hryvnia"]),
        ("GEL", ["₾", "gel", "лари", "lari"]),
        ("TRY", ["₺", "лир", "lira"]),
        ("AED", ["aed", "дирхам", "dirham"]),
        ("JPY", ["¥", "jpy", "иен", "yen"]),
        ("CNY", ["cny", "юан", "yuan"])
    ]

    // MARK: Числительные словами

    private static let russianUnits: [String: Decimal] = [
        "ноль": 0, "один": 1, "одна": 1, "два": 2, "две": 2, "три": 3,
        "четыре": 4, "пять": 5, "шесть": 6, "семь": 7, "восемь": 8,
        "девять": 9, "десять": 10, "одиннадцать": 11, "двенадцать": 12,
        "тринадцать": 13, "четырнадцать": 14, "пятнадцать": 15,
        "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18,
        "девятнадцать": 19, "двадцать": 20, "тридцать": 30, "сорок": 40,
        "пятьдесят": 50, "шестьдесят": 60, "семьдесят": 70,
        "восемьдесят": 80, "девяносто": 90, "сто": 100, "двести": 200,
        "триста": 300, "четыреста": 400, "пятьсот": 500, "шестьсот": 600,
        "семьсот": 700, "восемьсот": 800, "девятьсот": 900
    ]

    private static let englishUnits: [String: Decimal] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Множители читаются отдельно: «две тысячи», «три миллиона», «5k».
    private static let multipliers: [String: Decimal] = [
        "тысяч": 1_000, "тыщ": 1_000, "тыс": 1_000,
        "миллион": 1_000_000, "млн": 1_000_000, "лям": 1_000_000,
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "k": 1_000
    ]

    /// Разговорные названия сумм.
    ///
    /// Живая речь почти не пользуется числительными: люди говорят «косарь»
    /// и «полтинник», а не «одна тысяча» и «пятьдесят». Без этого словаря
    /// половина фраз о деньгах вообще не распознаётся как трата.
    private static let colloquialAmounts: [String: Decimal] = [
        "полтинник": 50, "полтос": 50,
        "стольник": 100, "сотка": 100, "сотня": 100,
        "двушка": 200,
        "пятихатка": 500, "пятиха": 500, "пятьсотка": 500,
        "косарь": 1_000, "косаря": 1_000, "штука": 1_000, "штуки": 1_000,
        "тонна": 1_000, "рубль": 1
    ]

    /// Дробные суммы разговором: «полторы тысячи», «два с половиной косаря».
    private static let fractionalPrefixes: [String: Decimal] = [
        "полтора": Decimal(string: "1.5")!,
        "полторы": Decimal(string: "1.5")!,
        "пол": Decimal(string: "0.5")!
    ]

    // MARK: Точка входа

    /// Находит первую сумму в тексте.
    static func extract(from text: String, defaultCurrency: String? = nil) -> Result? {
        if let numeric = extractNumeric(from: text, defaultCurrency: defaultCurrency) {
            return numeric
        }
        return extractSpelled(from: text, defaultCurrency: defaultCurrency)
    }

    // MARK: Цифры

    /// Разбирает «300», «1 500,50», «$46», «46 USD», «2к».
    private static func extractNumeric(from text: String, defaultCurrency: String?) -> Result? {
        // Отрицательный просмотр назад отсекает числа внутри слов и дат.
        // Raw-строка: в регексе много обратных слэшей, и экранировать
        // их дважды значит однажды ошибиться.
        let pattern = #"(?<![\p{L}\d])(\d{1,3}(?:[ .,]\d{3})+|\d+)(?:[.,](\d{1,2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let numberRange = match.range(at: 1)
            guard numberRange.location != NSNotFound else { continue }

            let digits = nsText.substring(with: numberRange)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: "")

            var literal = digits
            if match.range(at: 2).location != NSNotFound {
                literal += "." + nsText.substring(with: match.range(at: 2))
            }

            guard var value = Decimal(string: literal), value > 0 else { continue }

            if let multiplier = trailingMultiplier(after: match.range, in: nsText) {
                value *= multiplier
            }

            let context = surroundingContext(of: match.range, in: nsText)
            let explicitCurrency = currencyCode(in: context)

            return Result(
                amount: value,
                currencyCode: explicitCurrency ?? defaultCurrency,
                hasExplicitCurrency: explicitCurrency != nil,
                matchedText: nsText.substring(with: match.range)
            )
        }
        return nil
    }

    /// Множитель сразу после числа: «2к», «5 тысяч», «3 млн».
    private static func trailingMultiplier(after range: NSRange, in text: NSString) -> Decimal? {
        let start = range.location + range.length
        guard start < text.length else { return nil }

        let tailLength = min(12, text.length - start)
        let tail = IntentKeywords
            .normalize(text.substring(with: NSRange(location: start, length: tailLength)))
            .trimmingCharacters(in: .whitespaces)

        for (marker, value) in multipliers where tail.hasPrefix(marker) {
            return value
        }
        return nil
    }

    // MARK: Числительные словами

    /// Разбирает «триста рублей», «сорок шесть долларов», «two thousand».
    private static func extractSpelled(from text: String, defaultCurrency: String?) -> Result? {
        let normalized = IntentKeywords.normalize(text)
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var total: Decimal = 0
        var current: Decimal = 0
        var matched: [String] = []
        var sawNumber = false

        for word in words {
            if let unit = russianUnits[word] ?? englishUnits[word] {
                current += unit
                matched.append(word)
                sawNumber = true
                continue
            }

            // «Косарь», «полтинник», «пятихатка»: разговорная сумма сама
            // по себе завершённая, множитель к ней не применяется.
            if let colloquial = colloquialAmounts.first(where: { word.hasPrefix($0.key) })?.value {
                current = current == 0 ? colloquial : current * colloquial
                total += current
                current = 0
                matched.append(word)
                sawNumber = true
                continue
            }

            // «Полторы тысячи»: дробный множитель ждёт следующего слова.
            if let fraction = fractionalPrefixes.first(where: { word == $0.key })?.value {
                current = fraction
                matched.append(word)
                sawNumber = true
                continue
            }

            if let multiplier = multipliers.first(where: { word.hasPrefix($0.key) })?.value {
                // «тысяча» без числа перед ней означает одну тысячу.
                current = current == 0 ? multiplier : current * multiplier
                total += current
                current = 0
                matched.append(word)
                sawNumber = true
                continue
            }

            // Число уже набрано, дальше не идём: иначе «три рубля и пять яблок»
            // слипнутся в одну сумму.
            if sawNumber { break }
        }

        total += current
        guard sawNumber, total > 0 else { return nil }

        let explicitCurrency = currencyCode(in: normalized)
        return Result(
            amount: total,
            currencyCode: explicitCurrency ?? defaultCurrency,
            hasExplicitCurrency: explicitCurrency != nil,
            matchedText: matched.joined(separator: " ")
        )
    }

    // MARK: Валюта

    /// Код валюты по маркеру в тексте.
    static func currencyCode(in text: String) -> String? {
        let normalized = IntentKeywords.normalize(text)
        for (code, markers) in currencyMarkers {
            if markers.contains(where: { normalized.contains($0) }) {
                return code
            }
        }
        return nil
    }

    /// Окно вокруг найденного числа: валюта стоит вплотную к сумме,
    /// а не в другом конце фразы.
    private static func surroundingContext(of range: NSRange, in text: NSString) -> String {
        let start = max(0, range.location - 12)
        let end = min(text.length, range.location + range.length + 14)
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
