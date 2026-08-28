import Foundation
import XCTest
@testable import AILifeAssistant

/// Разбор живых фраз: места, где приложение молча понимало сказанное
/// неправильно и создавало правдоподобную, но неверную запись.
final class ParsingFixesTests: XCTestCase {

    private let parser = FastPathParser()

    private var context: ParsingContext {
        ParsingContext(
            referenceDate: Date(timeIntervalSince1970: 1_787_000_000),
            languageCode: "ru-RU",
            defaultCurrencyCode: "RUB"
        )
    }

    // MARK: Заголовки

    /// Маркеры это корни, и вырезание ровно корня оставляло в заголовке
    /// огрызок слова: «напомни позвонить маме» давало «И позвонить маме».
    func testTitleKeepsWholeWords() async throws {
        let cases: [(phrase: String, expected: String)] = [
            ("напомни позвонить маме", "Позвонить маме"),
            ("нужно позвонить Ване", "Позвонить Ване"),
            ("надо забрать посылку", "Забрать посылку")
        ]

        for (phrase, expected) in cases {
            let intent = try await parser.parse(text: phrase, context: context)
            let item = try XCTUnwrap(intent.items.first, "Фраза «\(phrase)» должна разобраться")
            XCTAssertEqual(item.title, expected, "Заголовок из «\(phrase)»")
        }
    }

    /// Глагол действия это и есть задача, удалять его нельзя.
    func testTaskTitleKeepsActionVerb() async throws {
        let intent = try await parser.parse(text: "нужно позвонить в банк", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .task)
        XCTAssertTrue(item.title.lowercased().contains("позвонить"), "Получено: \(item.title)")
    }

    // MARK: Суммы

    /// Количество товара стоит левее цены, и раньше выигрывало у неё.
    func testAmountPrefersPriceOverQuantity() {
        let cases: [(phrase: String, expected: Decimal)] = [
            ("купил 2 кофе за 300 рублей", 300),
            ("взял 3 билета по 1500", 1500),
            ("заказал 5 упаковок за 800", 800)
        ]

        for (phrase, expected) in cases {
            let result = AmountExtractor.extract(from: phrase, defaultCurrency: "RUB")
            XCTAssertEqual(result?.amount, expected, "Сумма из «\(phrase)»")
        }
    }

    /// Время и дата это не деньги.
    func testAmountIgnoresClockAndDate() {
        let meeting = AmountExtractor.extract(
            from: "встреча в 15:30, оплатить счёт 2000 рублей",
            defaultCurrency: "RUB"
        )
        XCTAssertEqual(meeting?.amount, 2000)

        let deadline = AmountExtractor.extract(
            from: "оплатить до 25 августа 3000 рублей",
            defaultCurrency: "RUB"
        )
        XCTAssertEqual(deadline?.amount, 3000)
    }

    func testCyrillicThousandsShorthand() {
        let result = AmountExtractor.extract(from: "снял 20к наличными", defaultCurrency: "RUB")
        XCTAssertEqual(result?.amount, 20_000)
    }

    /// Однобуквенный множитель не должен цепляться к обычному слову.
    func testDoesNotMultiplyByFollowingWord() {
        let result = AmountExtractor.extract(from: "купил 300 кофе", defaultCurrency: "RUB")
        XCTAssertEqual(result?.amount, 300, "«кофе» это не множитель на тысячу")
    }

    /// Разговорные суммы сопоставлялись по префиксу и ловили посторонние слова.
    func testColloquialAmountDoesNotMatchLongerWord() {
        let result = AmountExtractor.extract(from: "заказал штукатурку", defaultCurrency: "RUB")
        XCTAssertNil(result?.amount, "«Штукатурка» это не тысяча рублей")
    }

    // MARK: Тип записи

    /// Инфинитивами люди диктуют дела чаще всего, а они проваливались
    /// в заметки и до списка дел не доходили.
    func testInfinitivesBecomeTasks() async throws {
        for phrase in ["купить хлеб и молоко", "сходить к врачу", "заехать в сервис"] {
            let intent = try await parser.parse(text: phrase, context: context)
            let item = try XCTUnwrap(intent.items.first, "Фраза «\(phrase)» должна разобраться")
            XCTAssertEqual(item.kind, .task, "Фраза «\(phrase)» это дело, а не заметка")
        }
    }

    // MARK: Приоритет

    func testNegatedPriority() {
        XCTAssertEqual(IntentKeywords.priority(in: "это не срочно, сделать на следующей неделе"), .low)
        XCTAssertEqual(IntentKeywords.priority(in: "дело неважное, когда-нибудь посмотреть"), .low)
        XCTAssertEqual(IntentKeywords.priority(in: "срочно позвонить в банк"), .high)
    }

    /// Короткие маркеры искались подстрокой: «надо» находилось внутри
    /// «надоело», «потом» внутри «потому».
    func testShortMarkersRespectWordBoundaries() {
        XCTAssertFalse(
            IntentKeywords.contains("надоело ждать ответа", any: IntentKeywords.task),
            "«Надоело» это не «надо»"
        )
        XCTAssertEqual(
            IntentKeywords.priority(in: "потому что так удобнее"),
            .none,
            "«Потому» это не «потом»"
        )
    }

    // MARK: Время

    /// «Чек» заканчивается на «к», и шаблон времени цеплялся за неё.
    func testDoesNotReadAmountAsTime() {
        let result = DateExtractor.extract(from: "оплатить чек 1500", context: context)

        if let result, result.hasExplicitTime {
            let hour = context.calendar.component(.hour, from: result.date)
            XCTFail("Сумма 1500 прочитана как время \(hour):00")
        }
    }

    // MARK: Повторение

    func testRecurrenceReachesParsedItem() async throws {
        let intent = try await parser.parse(
            text: "напомни каждый день в 9 пить витамины",
            context: context
        )
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .reminder)
        XCTAssertEqual(item.recurrenceRule, "daily", "Правило должно доехать до сущности, а не остаться текстом")
    }

    @MainActor
    func testDailyReminderGetsRepeatingTrigger() throws {
        let reminder = Reminder(
            title: "Пить витамины",
            fireDate: Date(timeIntervalSince1970: 1_787_000_000),
            recurrenceRule: "daily"
        )

        let components = try XCTUnwrap(
            NotificationService.recurringComponents(for: reminder),
            "Повторяющееся напоминание должно давать повторяющийся триггер"
        )
        XCTAssertNotNil(components.hour)
        XCTAssertNotNil(components.minute)
        XCTAssertNil(components.day, "Повтор каждый день не должен быть привязан к числу месяца")
    }

    @MainActor
    func testWeeklyReminderKeepsWeekday() throws {
        let reminder = Reminder(
            title: "Планёрка",
            fireDate: Date(timeIntervalSince1970: 1_787_000_000),
            recurrenceRule: "weekly:mon"
        )

        let components = try XCTUnwrap(NotificationService.recurringComponents(for: reminder))
        XCTAssertEqual(components.weekday, 2, "Понедельник это второй день недели в календаре Apple")
    }

    @MainActor
    func testOneOffReminderHasNoRecurrence() throws {
        let reminder = Reminder(title: "Позвонить", fireDate: .now.addingTimeInterval(3600))
        XCTAssertNil(NotificationService.recurringComponents(for: reminder))
    }

    // MARK: Место траты

    func testMerchantNormalizedToNominative() {
        XCTAssertEqual(MerchantExtractor.extract(from: "купил кофе в Пятёрочке за 300"), "Пятёрочка")
        XCTAssertEqual(MerchantExtractor.extract(from: "взял продукты в Ленте"), "Лента")
    }

    func testCityIsNotAMerchant() {
        XCTAssertNil(MerchantExtractor.extract(from: "потратил 500 в Москве"))
    }
}
