import Foundation
import XCTest
@testable import AILifeAssistant

/// Разбор живой речи, а не образцовых формулировок.
///
/// Фразы здесь намеренно неряшливые: люди говорят «косарь» вместо «тысяча»,
/// «полдевятого» вместо «восемь тридцать» и почти всегда называют место.
/// Тест на аккуратной фразе доказывает только то, что аккуратные фразы
/// работают, а таких в жизни почти не бывает.
final class RealPhrasesTests: XCTestCase {

    private let parser = FastPathParser()

    private var context: ParsingContext {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26
        components.hour = 10

        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        calendar.timeZone = timeZone

        return ParsingContext(
            referenceDate: calendar.date(from: components) ?? Date(),
            timeZone: timeZone,
            languageCode: "ru-RU",
            defaultCurrencyCode: "RUB"
        )
    }

    // MARK: Разговорные суммы

    func testColloquialAmounts() throws {
        let cases: [(phrase: String, amount: Decimal)] = [
            ("отдал косарь за такси", 1000),
            ("потратил полтинник на кофе", 50),
            ("закинул стольник на телефон", 100),
            ("пятихатка за доставку", 500),
            ("штука за подписку", 1000)
        ]

        for (phrase, expected) in cases {
            let result = try XCTUnwrap(
                AmountExtractor.extract(from: phrase, defaultCurrency: "RUB"),
                "Фраза «\(phrase)» должна содержать сумму"
            )
            XCTAssertEqual(result.amount, expected, "Неверная сумма во фразе «\(phrase)»")
        }
    }

    func testThousandsColloquial() throws {
        let result = try XCTUnwrap(AmountExtractor.extract(from: "две тыщи за ужин"))
        XCTAssertEqual(result.amount, 2000)
    }

    // MARK: Дробное время

    /// «Полдевятого» это 8:30, а не 9:30: счёт идёт к названному часу.
    /// Ошибка сдвигает напоминание на час, и человек опаздывает.
    func testHalfHourMeansBeforeNamedHour() throws {
        let result = try XCTUnwrap(
            DateExtractor.extract(from: "напомни завтра в полдевятого", context: context)
        )

        let parts = context.calendar.dateComponents([.hour, .minute], from: result.date)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 30)
    }

    func testHalfHourEvening() throws {
        let result = try XCTUnwrap(
            DateExtractor.extract(from: "встреча в полшестого вечера", context: context)
        )

        let parts = context.calendar.dateComponents([.hour, .minute], from: result.date)
        XCTAssertEqual(parts.hour, 17)
        XCTAssertEqual(parts.minute, 30)
    }

    // MARK: Повторение

    func testRecurrenceRules() {
        XCTAssertEqual(DateExtractor.recurrenceRule(in: "каждый день пить витамины"), "daily")
        XCTAssertEqual(DateExtractor.recurrenceRule(in: "по понедельникам созвон"), "weekly:mon")
        XCTAssertEqual(DateExtractor.recurrenceRule(in: "по будням зарядка"), "weekdays")
        XCTAssertNil(DateExtractor.recurrenceRule(in: "завтра позвонить"))
    }

    // MARK: Место траты

    /// Известные сети приводятся к именительному падежу: иначе отчёт
    /// по местам рассыпается на «Пятёрочке», «Пятёрочку» и «Пятёрочка».
    /// Незнакомое название остаётся как есть, выдумывать его форму не из чего.
    func testMerchantExtraction() {
        XCTAssertEqual(MerchantExtractor.extract(from: "взял кофе в Скуратове"), "Скуратове")
        XCTAssertEqual(MerchantExtractor.extract(from: "купил продукты в Пятёрочке"), "Пятёрочка")
        XCTAssertEqual(MerchantExtractor.extract(from: "заправился на Лукойле"), "Лукойл")
    }

    /// Нарицательное место ничего не добавляет к категории и только
    /// засоряет отчёт.
    func testIgnoresGenericPlaces() {
        XCTAssertNil(MerchantExtractor.extract(from: "пообедал в кафе"))
        XCTAssertNil(MerchantExtractor.extract(from: "купил в магазине"))
        XCTAssertNil(MerchantExtractor.extract(from: "оплатил в аптеке"))
    }

    // MARK: Разбор целиком

    func testFullPhraseWithColloquialAmountAndPlace() async throws {
        let intent = try await parser.parse(text: "отдал косарь в Пятёрочке", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .expense)
        XCTAssertEqual(item.amount, 1000)
        XCTAssertEqual(item.merchant, "Пятёрочка")
    }

    func testReminderKeepsRecurrence() async throws {
        let intent = try await parser.parse(
            text: "напомни каждый день в полдевятого пить витамины",
            context: context
        )
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .reminder)
        XCTAssertTrue(item.details.contains("daily"), "Повторение не должно теряться")

        let parts = context.calendar.dateComponents([.hour, .minute], from: try XCTUnwrap(item.dueDate))
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 30)
    }
}
