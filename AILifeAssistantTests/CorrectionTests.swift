import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Голосовые исправления: человек поправляет себя вслух, и приложение
/// обязано понять, что это правка, а не новая запись.
@MainActor
final class CorrectionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    private var parsingContext: ParsingContext {
        ParsingContext(referenceDate: Date(timeIntervalSince1970: 1_787_000_000), languageCode: "ru-RU")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: Распознавание

    func testDetectsAmountCorrection() throws {
        XCTAssertTrue(CorrectionDetector.looksLikeCorrection("не сорок шесть, а шестьдесят четыре"))

        let correction = try XCTUnwrap(
            CorrectionDetector.detect(in: "не сорок шесть, а шестьдесят четыре", context: parsingContext)
        )

        guard case .amount(let value) = correction.target else {
            return XCTFail("Ожидалось исправление суммы, получено \(correction.target)")
        }
        XCTAssertEqual(value, 64, "Берётся значение после связки, а не до неё")
    }

    func testDetectsNumericAmountCorrection() throws {
        let correction = try XCTUnwrap(
            CorrectionDetector.detect(in: "не 46, а 64 доллара", context: parsingContext)
        )

        guard case .amount(let value) = correction.target else {
            return XCTFail("Ожидалось исправление суммы")
        }
        XCTAssertEqual(value, 64)
    }

    func testDetectsCancellation() throws {
        for phrase in ["отмени", "удали последнее", "забудь это", "cancel that"] {
            let correction = try XCTUnwrap(
                CorrectionDetector.detect(in: phrase, context: parsingContext),
                "Фраза «\(phrase)» должна распознаваться как отмена"
            )
            XCTAssertEqual(correction.target, .cancellation)
        }
    }

    /// Одного «не» мало: «не забудь купить молоко» это обычная задача,
    /// и превращать её в исправление нельзя.
    func testDoesNotTreatOrdinaryPhraseAsCorrection() {
        let phrases = [
            "не забудь купить молоко",
            "не забудь про встречу в пятницу",
            "нужно не забыть позвонить",
            "купил кофе за 300"
        ]

        for phrase in phrases {
            XCTAssertFalse(
                CorrectionDetector.looksLikeCorrection(phrase),
                "Фраза «\(phrase)» не должна считаться исправлением"
            )
        }
    }

    // MARK: Применение

    func testAppliesAmountCorrectionToRecentExpense() throws {
        let capture = CaptureItem(text: "купил кофе за 46")
        context.insert(capture)

        let expense = Expense(amount: 46, currencyCode: "USD", category: .food, source: capture)
        context.insert(expense)
        try context.save()

        let applier = CorrectionApplier(modelContext: context)
        let correction = CorrectionDetector.Correction(
            target: .amount(64),
            confidence: 0.9,
            matchedText: "64"
        )

        let outcome = applier.apply(correction)

        XCTAssertEqual(outcome.action, .amountChanged(from: 46, to: 64))
        XCTAssertEqual(expense.amount, 64)
        XCTAssertEqual(expense.confidence, 1, "Правка человеком надёжнее любого разбора")
    }

    /// Текст захвата тоже правится: иначе повторный разбор вернёт
    /// старую сумму и перезатрёт исправление.
    func testCorrectionUpdatesCaptureText() throws {
        let capture = CaptureItem(text: "купил кофе за 46")
        context.insert(capture)
        context.insert(Expense(amount: 46, source: capture))
        try context.save()

        let applier = CorrectionApplier(modelContext: context)
        _ = applier.apply(
            CorrectionDetector.Correction(target: .amount(64), confidence: 0.9, matchedText: "64")
        )

        XCTAssertTrue(capture.text.contains("64"))
        XCTAssertFalse(capture.text.contains("46"))
    }

    func testCancellationRemovesRecentCapture() throws {
        let capture = CaptureItem(text: "случайная запись")
        context.insert(capture)
        try context.save()

        let applier = CorrectionApplier(modelContext: context)
        let outcome = applier.apply(
            CorrectionDetector.Correction(target: .cancellation, confidence: 0.9, matchedText: "отмени")
        )

        XCTAssertEqual(outcome.action, .captureRemoved)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CaptureItem>()).isEmpty)
    }

    /// Старая запись не должна правиться: фраза через полчаса почти
    /// наверняка означает что-то другое.
    func testIgnoresCaptureOutsideCorrectionWindow() throws {
        let capture = CaptureItem(
            text: "старая запись",
            createdAt: Date().addingTimeInterval(-CorrectionApplier.correctionWindow - 60)
        )
        context.insert(capture)
        try context.save()

        let applier = CorrectionApplier(modelContext: context)
        let outcome = applier.apply(
            CorrectionDetector.Correction(target: .amount(64), confidence: 0.9, matchedText: "64")
        )

        XCTAssertEqual(outcome.action, .noTarget)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CaptureItem>()).count, 1)
    }

    func testDateCorrectionMovesReminder() throws {
        let capture = CaptureItem(text: "напомни завтра")
        context.insert(capture)

        let oldDate = Date().addingTimeInterval(3600)
        let reminder = Reminder(title: "Позвонить", fireDate: oldDate, source: capture)
        context.insert(reminder)
        try context.save()

        let newDate = Date().addingTimeInterval(86_400)
        let applier = CorrectionApplier(modelContext: context)
        let outcome = applier.apply(
            CorrectionDetector.Correction(target: .date(newDate), confidence: 0.85, matchedText: "послезавтра")
        )

        guard case .dateChanged = outcome.action else {
            return XCTFail("Ожидалось изменение даты, получено \(outcome.action)")
        }
        XCTAssertEqual(reminder.fireDate.timeIntervalSince1970, newDate.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: Границы слова

    /// Слово «отменить» посреди предложения ничего не отменяет.
    ///
    /// Раньше маркер искался подстрокой, и любая фраза про отменённую
    /// встречу или подписку удаляла предыдущую запись вместе с аудиофайлом.
    func testDoesNotTreatWordInsideSentenceAsCancellation() {
        let phrases = [
            "встречу отменили, напомни позвонить Игорю",
            "нужно отменить подписку на Нетфликс",
            "они отменили рейс, надо перебронировать",
            "не забудь отменить бронь"
        ]

        for phrase in phrases {
            XCTAssertNil(
                CorrectionDetector.detect(in: phrase, context: parsingContext),
                "Фраза «\(phrase)» не должна распознаваться как отмена"
            )
        }
    }

    func testDetectsCancellationWithSupport() throws {
        let phrases = [
            "отмени", "отмени последнюю запись", "отмени это",
            "удали последнюю запись", "сотри последнее", "забудь про это"
        ]

        for phrase in phrases {
            let correction = try XCTUnwrap(
                CorrectionDetector.detect(in: phrase, context: parsingContext),
                "Фраза «\(phrase)» должна распознаваться как отмена"
            )
            XCTAssertEqual(correction.target, .cancellation)
        }
    }

    // MARK: Самопоправка

    /// «Нет, шестьдесят четыре» это то, как люди поправляют себя вслух
    /// чаще всего. Связки «а» в такой фразе нет, и раньше она проходила
    /// мимо, создавая вторую запись рядом с ошибочной.
    func testDetectsSelfCorrectionStartingWithNo() throws {
        let correction = try XCTUnwrap(
            CorrectionDetector.detect(in: "нет, 64 рубля", context: parsingContext)
        )

        guard case .amount(let value) = correction.target else {
            return XCTFail("Ожидалось исправление суммы, получено \(correction.target)")
        }
        XCTAssertEqual(value, 64)
    }

    func testDetectsSelfCorrectionInsideSentence() throws {
        let correction = try XCTUnwrap(
            CorrectionDetector.detect(in: "потратил 300, нет, 400 рублей", context: parsingContext)
        )

        guard case .amount(let value) = correction.target else {
            return XCTFail("Ожидалось исправление суммы, получено \(correction.target)")
        }
        XCTAssertEqual(value, 400)
    }

    /// А вот «нет» в середине обычной фразы поправкой не является.
    func testDoesNotTreatPlainNoAsCorrection() {
        let phrases = [
            "у меня нет времени, напомни позвонить в банк",
            "в магазине нет молока"
        ]

        for phrase in phrases {
            XCTAssertFalse(
                CorrectionDetector.looksLikeCorrection(phrase),
                "Фраза «\(phrase)» не должна считаться исправлением"
            )
        }
    }
}
