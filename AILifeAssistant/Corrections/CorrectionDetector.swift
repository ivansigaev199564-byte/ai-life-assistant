import Foundation

/// Распознавание исправлений в речи.
///
/// Человек, говорящий на ходу, ошибается и поправляет себя вслух:
/// «купил кофе за сорок шесть... нет, за шестьдесят четыре». Без разбора
/// таких фраз приложение создаст две записи вместо одной исправленной,
/// и пользователь потеряет доверие к нему быстрее, чем к любой другой
/// ошибке: он же ясно сказал, как правильно.
enum CorrectionDetector {

    /// Что именно исправляют.
    enum Target: Equatable, Sendable {
        case amount(Decimal)
        case date(Date)
        case title(String)
        /// Отмена последней записи целиком.
        case cancellation
    }

    struct Correction: Equatable, Sendable {
        let target: Target
        /// Насколько уверенно распознано исправление.
        let confidence: Double
        /// Фрагмент, по которому оно распознано.
        let matchedText: String
    }

    // MARK: Маркеры

    /// Отмена: «отмени», «удали последнее», «забудь про это».
    ///
    /// Маркеры намеренно длиннее очевидных. Короткое «забудь» ловит
    /// «не забудь купить молоко», то есть просьба не забыть удаляла бы
    /// предыдущую запись. Отмена сказанного всегда звучит определённее,
    /// чем одно слово посреди фразы.
    private static let cancellationMarkers = [
        "отмени", "отменить", "удали последн", "удалить последн", "сотри последн",
        "забудь это", "забудь последн", "забудь про это", "не надо записывать",
        "не нужно записывать", "не сохраняй",
        "cancel that", "delete that", "never mind", "forget that", "undo that"
    ]

    /// Обороты, внутри которых маркеры выглядят как отмена, но ею не являются.
    /// Проверяются первыми и снимают ложное срабатывание целиком.
    private static let cancellationExceptions = [
        "не забудь", "не забыть", "не забывай", "don't forget", "dont forget"
    ]

    /// Исправление: «не ..., а ...», «нет, ...», «вместо».
    private static let correctionMarkers = [
        "не ", "нет,", "нет ", "вместо", "исправь", "поправь", "точнее",
        "точне", "ошибся", "ошиблась",
        "not ", "no,", "actually", "instead", "correction", "i meant"
    ]

    /// Слова, за которыми следует верное значение: «а», «то есть», «rather».
    private static let replacementMarkers = [", а ", " а ", "то есть", "именно", "rather", "but "]

    // MARK: Разбор

    /// Похожа ли фраза на исправление предыдущей записи.
    ///
    /// Проверяется отдельно от разбора: конвейеру нужно решить, создавать
    /// новую запись или править старую, до того как он начнёт извлекать
    /// сущности.
    static func looksLikeCorrection(_ text: String) -> Bool {
        let normalized = IntentKeywords.normalize(text)

        // «Не забудь» это просьба запомнить, а не отменить.
        if cancellationExceptions.contains(where: { normalized.contains($0) }) {
            return false
        }

        if cancellationMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        // Одного «не» мало: «не забудь купить молоко» это обычная задача.
        // Нужен и маркер исправления, и слово-связка перед верным значением.
        let hasCorrectionMarker = correctionMarkers.contains { normalized.hasPrefix($0) || normalized.contains(" \($0)") }
        let hasReplacement = replacementMarkers.contains { normalized.contains($0) }

        return hasCorrectionMarker && hasReplacement
    }

    /// Извлекает исправление из фразы.
    static func detect(in text: String, context: ParsingContext) -> Correction? {
        let normalized = IntentKeywords.normalize(text)

        guard !cancellationExceptions.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        if let marker = cancellationMarkers.first(where: { normalized.contains($0) }) {
            return Correction(target: .cancellation, confidence: 0.9, matchedText: marker)
        }

        guard looksLikeCorrection(text) else { return nil }

        // Верное значение стоит после связки: «не сорок шесть, а шестьдесят
        // четыре». Разбираем именно правую часть, иначе поймаем ошибочное.
        let replacement = rightHandSide(of: text) ?? text

        if let amount = AmountExtractor.extract(from: replacement, defaultCurrency: nil) {
            return Correction(
                target: .amount(amount.amount),
                confidence: amount.hasExplicitCurrency ? 0.9 : 0.8,
                matchedText: amount.matchedText
            )
        }

        if let date = DateExtractor.extract(from: replacement, context: context) {
            return Correction(
                target: .date(DateExtractor.normalizedFireDate(from: date, context: context)),
                confidence: 0.85,
                matchedText: date.matchedText
            )
        }

        // Ни суммы, ни даты: считаем, что правят формулировку.
        let title = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return nil }

        return Correction(target: .title(title), confidence: 0.6, matchedText: title)
    }

    /// Часть фразы после слова-связки.
    private static func rightHandSide(of text: String) -> String? {
        let lowered = text.lowercased()

        // Берём самую позднюю связку: в «не сорок шесть, а шестьдесят четыре»
        // верное значение всегда правее.
        var bestRange: Range<String.Index>?

        for marker in replacementMarkers {
            guard let range = lowered.range(of: marker, options: .backwards) else { continue }
            if bestRange == nil || range.lowerBound > bestRange!.lowerBound {
                bestRange = range
            }
        }

        guard let bestRange else { return nil }
        return String(text[bestRange.upperBound...])
    }
}
