import Foundation
import NaturalLanguage

/// Извлечение имён людей из фразы.
///
/// Опирается на NaturalLanguage, но не только: для русского распознавание
/// имён работает неровно, а речь идёт в падежах («позвонить Мише»), поэтому
/// поверх добавлена эвристика и сопоставление с уже известными людьми.
enum PersonExtractor {

    /// Сколько первых символов должно совпасть, чтобы считать «Мише»
    /// и «Миша» одним человеком. Четыре достаточно для коротких имён
    /// и не склеивает «Аня» с «Антон».
    private static let matchPrefixLength = 4

    /// Слова, которые часто идут с заглавной буквы, но людьми не являются.
    private static let stopWords: Set<String> = [
        "я", "мне", "меня", "мы", "нам", "он", "она", "они",
        "напомни", "сегодня", "завтра", "послезавтра", "вечером", "утром",
        "i", "me", "we", "he", "she", "they", "remind", "today", "tomorrow"
    ]

    /// Находит упоминания людей и приводит их к каноническим именам,
    /// если такой человек уже известен приложению.
    static func extract(from text: String, context: ParsingContext) -> [String] {
        var found = linguisticNames(in: text)

        if found.isEmpty {
            found = capitalizedCandidates(in: text)
        }

        // Сопоставление с известными: «Мише» превращается в «Миша»,
        // иначе на каждое упоминание заведётся новая карточка.
        let canonical = found.map { candidate in
            matchKnownPerson(candidate, among: context.knownPeople) ?? candidate
        }

        // Убираем повторы, сохраняя порядок появления в фразе.
        var seen = Set<String>()
        return canonical.filter { name in
            let key = name.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    // MARK: Системный разбор

    /// Имена, размеченные NaturalLanguage.
    private static func linguisticNames(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var names: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            if tag == .personalName {
                let name = String(text[range]).trimmingCharacters(in: .whitespaces)
                if isPlausibleName(name) { names.append(name) }
            }
            return true
        }
        return names
    }

    // MARK: Эвристика

    /// Слова с заглавной буквы не в начале фразы: запасной путь,
    /// когда системный разбор ничего не нашёл.
    private static func capitalizedCandidates(in text: String) -> [String] {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        var candidates: [String] = []

        for (index, rawWord) in words.enumerated() {
            let word = rawWord.trimmingCharacters(in: .punctuationCharacters)
            guard index > 0, isPlausibleName(word) else { continue }
            guard let first = word.first, first.isUppercase else { continue }
            candidates.append(word)
        }
        return candidates
    }

    private static func isPlausibleName(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 30 else { return false }
        guard !stopWords.contains(word.lowercased()) else { return false }
        // Имя состоит из букв и, возможно, дефиса: «Жан-Поль».
        return word.allSatisfy { $0.isLetter || $0 == "-" }
    }

    // MARK: Сопоставление с известными

    /// Ищет известного человека, к которому относится упоминание.
    ///
    /// Русский склоняет имена, поэтому сравниваем по общему началу слова,
    /// а не по точному совпадению.
    static func matchKnownPerson(_ candidate: String, among known: [String]) -> String? {
        let normalizedCandidate = normalize(candidate)
        guard !normalizedCandidate.isEmpty else { return nil }

        // Точное совпадение важнее приблизительного.
        if let exact = known.first(where: { normalize($0) == normalizedCandidate }) {
            return exact
        }

        return known.first { knownName in
            let normalizedKnown = normalize(knownName)
            let prefixLength = min(matchPrefixLength, min(normalizedKnown.count, normalizedCandidate.count))
            guard prefixLength >= matchPrefixLength else { return false }
            return normalizedKnown.prefix(prefixLength) == normalizedCandidate.prefix(prefixLength)
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
