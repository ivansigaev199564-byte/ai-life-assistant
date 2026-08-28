import Foundation

/// Где потрачены деньги.
///
/// Живая речь почти всегда называет место: «взял кофе в Скуратове»,
/// «заправился на Лукойле», «купил в Пятёрочке». Без этого расход
/// превращается в безликую сумму, и месячный отчёт перестаёт что-либо
/// объяснять: видно, что ушло двенадцать тысяч на еду, и непонятно куда.
enum MerchantExtractor {

    /// Предлоги, после которых обычно идёт место.
    private static let placeMarkers = ["в ", "во ", "на ", "у ", "из ", "at ", "in ", "from "]

    /// Слова, которые идут после предлога, но местом не являются.
    private static let stopWords: Set<String> = [
        "магазин", "кафе", "ресторан", "аптеке", "аптека", "работе", "работу",
        "дом", "дома", "домой", "офис", "офисе", "обед", "ужин", "завтрак",
        "субботу", "воскресенье", "понедельник", "вторник", "среду", "четверг",
        "пятницу", "утром", "вечером", "днем", "ночью", "неделю", "месяц",
        "счет", "счёт", "сумме", "размере", "общем", "итоге", "целом"
    ]

    /// Находит название места.
    ///
    /// Опирается на заглавную букву: собственные имена пишутся с неё,
    /// а распознавание речи это сохраняет. Нарицательные вроде «в магазине»
    /// отсекаются словарём: они ничего не добавляют к категории расхода.
    static func extract(from text: String) -> String? {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        guard words.count >= 2 else { return nil }

        for (index, word) in words.enumerated() where index + 1 < words.count {
            let lowered = word.lowercased() + " "
            guard placeMarkers.contains(lowered) else { continue }

            let candidate = words[index + 1]
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)

            guard isPlausiblePlace(candidate) else { continue }
            return normalizeCase(candidate)
        }
        return nil
    }

    private static func isPlausiblePlace(_ word: String) -> Bool {
        guard word.count >= 3, word.count <= 30 else { return false }
        guard let first = word.first, first.isUppercase || first.isLetter else { return false }
        guard !stopWords.contains(word.lowercased()) else { return false }

        // Город местом траты не является: «взял кофе в Москве» не должно
        // заводить магазин с названием «Москве».
        guard !cities.contains(IntentKeywords.normalize(word)) else { return false }

        // Числа и суммы местом быть не могут.
        guard !word.contains(where: \.isNumber) else { return false }

        // Собственное имя почти всегда с заглавной. Слово со строчной
        // берём только если оно похоже на известную сеть.
        if let first = word.first, first.isUppercase { return true }
        return isKnownChain(word)
    }

    private static func isKnownChain(_ word: String) -> Bool {
        let normalized = IntentKeywords.normalize(word)
        return chainRoots.keys.contains { normalized.hasPrefix($0) }
    }

    /// Корень названия и его именительный падеж.
    ///
    /// Речь склоняет всё: «в Пятёрочке», «из Ленты», «на Лукойле». Без
    /// приведения к одной форме отчёт по местам рассыпается на варианты
    /// одного и того же магазина.
    private static let chainRoots: [String: String] = [
        "пятерочк": "Пятёрочка", "пятёрочк": "Пятёрочка",
        "магнит": "Магнит",
        "перекрестк": "Перекрёсток", "перекрёстк": "Перекрёсток",
        "перекресток": "Перекрёсток", "перекрёсток": "Перекрёсток",
        "ашан": "Ашан",
        "лент": "Лента",
        "вкусвилл": "ВкусВилл",
        "азбук": "Азбука вкуса",
        "дикси": "Дикси",
        "окей": "Окей",
        "лукойл": "Лукойл",
        "роснефт": "Роснефть",
        "газпромнефт": "Газпромнефть",
        "яндекс": "Яндекс",
        "озон": "Озон",
        "вайлдберриз": "Вайлдберриз",
        "старбакс": "Старбакс",
        "макдональдс": "Макдональдс",
        "кфс": "КФС",
        "бургеркинг": "Бургер Кинг",
        "додо": "Додо"
    ]

    /// Города: после предлога они выглядят как место траты, но им не являются.
    private static let cities: Set<String> = [
        "москве", "москва", "питере", "петербурге", "спб", "казани", "сочи",
        "новосибирске", "екатеринбурге", "тбилиси", "ереване", "стамбуле",
        "дубае", "белграде", "лиссабоне", "берлине", "лондоне", "париже"
    ]

    /// Приводит название к именительному падежу, если оно узнано,
    /// и к заглавной букве в остальных случаях.
    private static func normalizeCase(_ word: String) -> String {
        let normalized = IntentKeywords.normalize(word)

        // Самый длинный подходящий корень: «перекрестк» точнее, чем «перекр».
        if let canonical = chainRoots
            .filter({ normalized.hasPrefix($0.key) })
            .max(by: { $0.key.count < $1.key.count })?
            .value {
            return canonical
        }

        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
