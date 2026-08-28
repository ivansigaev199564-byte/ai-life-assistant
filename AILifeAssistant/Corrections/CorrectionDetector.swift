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

    /// Отмена как самостоятельная реплика: человек сказал только это.
    ///
    /// Сравнивается со всей фразой целиком, а не ищется внутри неё. Поиск
    /// подстрокой стоил дорого: «встречу отменили, напомни позвонить Игорю»
    /// удаляло предыдущую запись вместе с аудиофайлом.
    private static let standaloneCancellations: Set<String> = [
        "отмени", "отмена", "отменить", "удали", "удалить", "сотри",
        "забудь", "не сохраняй", "не записывай",
        "cancel", "delete", "never mind", "nevermind", "forget it", "undo"
    ]

    /// Отмена с опорой: в самой фразе сказано, что именно отменяют.
    private static let cancellationPhrases = [
        "отмени последн", "отмени эту запись", "отмени запись", "отмени это",
        "отменить последн", "отменить запись",
        "удали последн", "удалить последн", "удали эту запись", "удали запись",
        "сотри последн", "сотри это", "сотри запись",
        "забудь это", "забудь последн", "забудь про это",
        "не надо записывать", "не нужно записывать", "не сохраняй это",
        "cancel that", "delete that", "forget that", "undo that", "delete the last"
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

    /// Слова, за которыми следует верное значение: «а», «то есть», «нет».
    ///
    /// «Нет» здесь только с запятой или окружённое пробелами: иначе «у меня
    /// нет времени, напомни позвонить» читалось бы как поправка.
    private static let replacementMarkers = [
        ", а ", " а ", "то есть", "именно", "вместо ",
        ", нет,", ", нет ", " нет, ",
        "rather", "but ", ", no,", " no, "
    ]

    /// Фраза целиком посвящена поправке: «нет, шестьдесят четыре».
    /// Связки в ней нет, но и сомнений тоже.
    private static let selfCorrectionPrefixes = ["нет,", "нет ", "no,", "no "]

    /// Что отбрасывается по краям при сравнении фразы целиком.
    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)

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

        if cancellationMarker(in: normalized) != nil {
            return true
        }

        // Одного «не» мало: «не забудь купить молоко» это обычная задача.
        // Нужен и маркер исправления, и слово-связка перед верным значением.
        let hasCorrectionMarker = correctionMarkers.contains { normalized.hasPrefix($0) || normalized.contains(" \($0)") }
        let hasReplacement = replacementMarkers.contains { normalized.contains($0) }

        if hasCorrectionMarker, hasReplacement {
            return true
        }

        // «Нет, шестьдесят четыре» сразу после записи: классическая
        // самопоправка, которую человек произносит чаще всего.
        return selfCorrectionTail(of: normalized) != nil
    }

    /// Хвост после «нет,» в начале фразы. Пустой хвост поправкой не считается.
    private static func selfCorrectionTail(of normalized: String) -> String? {
        guard let prefix = selfCorrectionPrefixes.first(where: { normalized.hasPrefix($0) }) else {
            return nil
        }

        let tail = normalized
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return tail.count >= 2 ? tail : nil
    }

    /// Отмена ли это.
    ///
    /// Либо вся фраза целиком про отмену, либо в ней прямо сказано, что
    /// именно отменяют. Просто слово «отменить» посреди предложения ничего
    /// не отменяет: «нужно отменить подписку» это задача, а не команда.
    private static func cancellationMarker(in normalized: String) -> String? {
        let whole = normalized.trimmingCharacters(in: edgeCharacters)

        if standaloneCancellations.contains(whole) {
            return whole
        }

        return cancellationPhrases.first { normalized.contains($0) }
    }

    /// Извлекает исправление из фразы.
    static func detect(in text: String, context: ParsingContext) -> Correction? {
        let normalized = IntentKeywords.normalize(text)

        guard !cancellationExceptions.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        if let marker = cancellationMarker(in: normalized) {
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

        if let bestRange {
            return String(text[bestRange.upperBound...])
        }

        // Связки нет, но фраза начинается с «нет,»: верное значение это всё
        // остальное. Смещение считаем по самой строке, а не по её копии
        // в нижнем регистре: индексы разных строк несовместимы.
        let normalized = IntentKeywords.normalize(text)
        guard let prefix = selfCorrectionPrefixes.first(where: { normalized.hasPrefix($0) }),
              text.count > prefix.count
        else { return nil }

        let start = text.index(text.startIndex, offsetBy: prefix.count)
        return String(text[start...])
    }
}
