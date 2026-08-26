import XCTest
@testable import AILifeAssistant

/// Локальный разбор: то, что пользователь видит мгновенно.
final class FastPathParserTests: XCTestCase {

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
            knownPeople: ["Миша"],
            knownProjects: ["Ремонт"],
            defaultCurrencyCode: "RUB"
        )
    }

    // MARK: Расходы

    func testParsesExpense() async throws {
        let intent = try await parser.parse(text: "купил кофе за 300 рублей", context: context)

        let item = try XCTUnwrap(intent.items.first)
        XCTAssertEqual(item.kind, .expense)
        XCTAssertEqual(item.amount, 300)
        XCTAssertEqual(item.currencyCode, "RUB")
        XCTAssertEqual(item.category, .food)
        XCTAssertTrue(item.isConfident, "Явная трата с категорией должна быть уверенной")
    }

    func testParsesExpenseCategoryFromContext() async throws {
        let intent = try await parser.parse(text: "заплатил 500 за такси", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .expense)
        XCTAssertEqual(item.category, .transport)
    }

    // MARK: Напоминания

    func testParsesReminderWithTime() async throws {
        let intent = try await parser.parse(
            text: "напомни завтра в девять позвонить в банк",
            context: context
        )

        let item = try XCTUnwrap(intent.items.first)
        XCTAssertEqual(item.kind, .reminder)
        XCTAssertNotNil(item.dueDate)
        XCTAssertTrue(item.isConfident)
        XCTAssertFalse(
            item.title.lowercased().contains("напомни"),
            "Служебное слово не должно попадать в заголовок"
        )
    }

    /// «Напомни» без времени всё равно даёт напоминание, но на утро.
    func testReminderWithoutTimeGetsDefaultFireDate() async throws {
        let intent = try await parser.parse(text: "напомни оплатить интернет", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .reminder)
        let fireDate = try XCTUnwrap(item.dueDate)
        XCTAssertGreaterThan(fireDate, context.referenceDate)
    }

    // MARK: Задачи и заметки

    func testParsesTask() async throws {
        let intent = try await parser.parse(text: "нужно заказать воду", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .task)
        XCTAssertNil(item.dueDate)
    }

    func testFallsBackToNote() async throws {
        let intent = try await parser.parse(
            text: "интересная мысль про устройство памяти",
            context: context
        )
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .note)
        XCTAssertFalse(item.details.isEmpty)
    }

    func testDetectsHighPriority() async throws {
        let intent = try await parser.parse(text: "срочно нужно отправить отчёт", context: context)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.priority, .high)
    }

    // MARK: Мульти-интент

    /// Главный сценарий из ТЗ: одна фраза, два разных действия.
    func testSplitsMultipleIntents() async throws {
        let intent = try await parser.parse(
            text: "купил кофе за 300 рублей и напомни завтра в девять позвонить Мише",
            context: context
        )

        XCTAssertEqual(intent.items.count, 2, "Ожидались расход и напоминание")

        let kinds = Set(intent.items.map(\.kind))
        XCTAssertTrue(kinds.contains(.expense))
        XCTAssertTrue(kinds.contains(.reminder))

        let expense = try XCTUnwrap(intent.items.first { $0.kind == .expense })
        XCTAssertEqual(expense.amount, 300)
    }

    /// Союз внутри одного действия не должен разрывать фразу.
    func testDoesNotSplitSingleIntent() async throws {
        let intent = try await parser.parse(text: "купил кофе и булочку за 300 рублей", context: context)
        XCTAssertEqual(intent.items.count, 1)
    }

    // MARK: Контекст

    func testMatchesKnownProject() async throws {
        let intent = try await parser.parse(text: "по проекту Ремонт выбрать плитку", context: context)
        XCTAssertTrue(intent.projects.contains("Ремонт"))
    }

    func testEmptyInputThrows() async {
        do {
            _ = try await parser.parse(text: "   ", context: context)
            XCTFail("Пустой ввод должен приводить к ошибке")
        } catch let error as ParsingError {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("Неожиданная ошибка: \(error)")
        }
    }

    // MARK: Английский

    func testParsesEnglishExpense() async throws {
        var englishContext = context
        englishContext.languageCode = "en-US"

        let intent = try await parser.parse(text: "spent 25 dollars on lunch", context: englishContext)
        let item = try XCTUnwrap(intent.items.first)

        XCTAssertEqual(item.kind, .expense)
        XCTAssertEqual(item.amount, 25)
        XCTAssertEqual(item.currencyCode, "USD")
    }

    // MARK: Скорость

    /// Разбор идёт в момент, когда пользователь ещё держит палец на кнопке:
    /// он обязан быть мгновенным.
    func testParsingIsFast() async throws {
        let intent = try await parser.parse(
            text: "купил кофе за 300 и напомни завтра позвонить Мише",
            context: context
        )
        XCTAssertLessThan(intent.duration, 0.5, "Локальный разбор должен укладываться в доли секунды")
    }
}
