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

        // Числа и суммы местом быть не могут.
        guard !word.contains(where: \.isNumber) else { return false }

        // Собственное имя почти всегда с заглавной. Слово со строчной
        // берём только если оно похоже на известную сеть.
        if let first = word.first, first.isUppercase { return true }
        return knownChains.contains(word.lowercased())
    }

    /// Сети, которые в речи часто звучат со строчной буквы.
    private static let knownChains: Set<String> = [
        "пятерочка", "пятёрочка", "магнит", "перекресток", "перекрёсток",
        "ашан", "лента", "вкусвилл", "азбука", "дикси", "окей",
        "лукойл", "роснефть", "газпромнефть", "яндекс", "озон", "вайлдберриз",
        "старбакс", "макдональдс", "кфс", "бургеркинг", "додо"
    ]

    /// Приводит первую букву к заглавной: «пятёрочка» становится «Пятёрочка».
    private static func normalizeCase(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
