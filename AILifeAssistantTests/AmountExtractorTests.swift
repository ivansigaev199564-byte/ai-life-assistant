import XCTest
@testable import AILifeAssistant

/// Суммы и валюты: то, на чём чаще всего ошибается разбор трат.
final class AmountExtractorTests: XCTestCase {

    func testExtractsSimpleAmountWithCurrencyWord() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "купил кофе за 300 рублей"))
        XCTAssertEqual(result.amount, 300)
        XCTAssertEqual(result.currencyCode, "RUB")
    }

    func testExtractsCurrencySymbolBeforeNumber() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "обед стоил $46"))
        XCTAssertEqual(result.amount, 46)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    func testExtractsCurrencySymbolAfterNumber() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "заплатил 46$ за такси"))
        XCTAssertEqual(result.amount, 46)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    /// Дробная часть в деньгах обязана сохраняться точно.
    func testExtractsFractionalAmount() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "оплатил 1250,50 рублей"))
        XCTAssertEqual(result.amount, Decimal(string: "1250.50"))
    }

    func testExtractsAmountWithThousandsSeparator() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "перевёл 1 500 рублей"))
        XCTAssertEqual(result.amount, 1500)
        XCTAssertEqual(result.currencyCode, "RUB")
    }

    /// Числительные словами: распознавание речи часто отдаёт именно их.
    func testExtractsSpelledRussianNumber() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "потратил триста рублей на кофе"))
        XCTAssertEqual(result.amount, 300)
        XCTAssertEqual(result.currencyCode, "RUB")
    }

    func testExtractsCompoundSpelledNumber() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "отдал сорок шесть долларов"))
        XCTAssertEqual(result.amount, 46)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    func testExtractsSpelledEnglishNumber() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "spent twenty five dollars on lunch"))
        XCTAssertEqual(result.amount, 25)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    func testExtractsThousandsMultiplier() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "заплатил две тысячи рублей"))
        XCTAssertEqual(result.amount, 2000)
    }

    /// Валюта по умолчанию подставляется, когда в фразе её нет.
    func testFallsBackToDefaultCurrency() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "отдал 500", defaultCurrency: "RUB"))
        XCTAssertEqual(result.amount, 500)
        XCTAssertEqual(result.currencyCode, "RUB")
    }

    func testReturnsNilWhenNoAmount() {
        XCTAssertNil(AmountExtractor.extract(from: "напомни позвонить маме"))
    }

    /// Ноль не является тратой и не должен создавать расход.
    func testIgnoresZeroAmount() {
        XCTAssertNil(AmountExtractor.extract(from: "потратил 0 рублей"))
    }

    func testDetectsVariousCurrencies() {
        XCTAssertEqual(AmountExtractor.currencyCode(in: "100 евро"), "EUR")
        XCTAssertEqual(AmountExtractor.currencyCode(in: "50 тенге"), "KZT")
        XCTAssertEqual(AmountExtractor.currencyCode(in: "20 лари"), "GEL")
        XCTAssertEqual(AmountExtractor.currencyCode(in: "30 фунтов"), "GBP")
        XCTAssertNil(AmountExtractor.currencyCode(in: "просто текст"))
    }
}
