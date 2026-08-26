import XCTest
@testable import AILifeAssistant

/// Даты разбираются от фиксированного момента, иначе тесты зависели бы
/// от времени запуска и падали бы по ночам.
final class DateExtractorTests: XCTestCase {

    /// Опорный момент: среда, 26 августа 2026 года, 10:00 по Москве.
    private var context: ParsingContext {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26
        components.hour = 10
        components.minute = 0

        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        calendar.timeZone = timeZone

        let reference = calendar.date(from: components) ?? Date()
        return ParsingContext(referenceDate: reference, timeZone: timeZone, languageCode: "ru-RU")
    }

    private func parts(_ date: Date) -> DateComponents {
        context.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: Относительное время

    func testInAnHour() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "напомни через час", context: context))
        XCTAssertEqual(parts(result.date).hour, 11)
        XCTAssertTrue(result.hasExplicitTime)
    }

    func testInTwentyMinutes() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "через 20 минут выйти", context: context))
        let components = parts(result.date)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 20)
    }

    func testInThreeDays() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "через 3 дня проверить", context: context))
        XCTAssertEqual(parts(result.date).day, 29)
        XCTAssertFalse(result.hasExplicitTime, "У суток нет конкретного времени")
    }

    func testHalfAnHour() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "через полчаса", context: context))
        XCTAssertEqual(parts(result.date).minute, 30)
    }

    // MARK: Именованные дни

    func testTomorrowWithSpelledTime() throws {
        let result = try XCTUnwrap(
            DateExtractor.extract(from: "напомни завтра в девять позвонить", context: context)
        )
        let components = parts(result.date)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, 9)
        XCTAssertTrue(result.hasExplicitTime)
    }

    func testTomorrowWithNumericTime() throws {
        let result = try XCTUnwrap(
            DateExtractor.extract(from: "завтра в 15:30 встреча", context: context)
        )
        let components = parts(result.date)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 30)
    }

    func testDayAfterTomorrow() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "послезавтра забрать посылку", context: context))
        XCTAssertEqual(parts(result.date).day, 28)
    }

    func testTodayWithoutTimeHasNoExplicitTime() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "сегодня сделать отчёт", context: context))
        XCTAssertEqual(parts(result.date).day, 26)
        XCTAssertFalse(result.hasExplicitTime)
    }

    // MARK: Дни недели

    /// Опорный день среда, поэтому «в пятницу» это 28 августа.
    func testUpcomingWeekday() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "в пятницу к врачу", context: context))
        XCTAssertEqual(parts(result.date).day, 28)
    }

    func testNextWeekWeekday() throws {
        let result = try XCTUnwrap(
            DateExtractor.extract(from: "в следующий понедельник созвон", context: context)
        )
        // Ближайший понедельник 31 августа, следующий за ним 7 сентября.
        let components = parts(result.date)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 7)
    }

    // MARK: Части суток

    func testEveningToday() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "вечером позвонить", context: context))
        let components = parts(result.date)
        XCTAssertEqual(components.day, 26)
        XCTAssertEqual(components.hour, 19)
    }

    /// Утро уже прошло, поэтому «утром» относится к завтрашнему дню.
    func testMorningMovesToNextDayWhenPassed() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "утром сходить в зал", context: context))
        XCTAssertEqual(parts(result.date).day, 27)
    }

    // MARK: Английский

    func testEnglishTomorrow() throws {
        var englishContext = context
        englishContext.languageCode = "en-US"

        let result = try XCTUnwrap(
            DateExtractor.extract(from: "remind me tomorrow at 9", context: englishContext)
        )
        let components = parts(result.date)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, 9)
    }

    func testEnglishRelative() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "in 2 hours call back", context: context))
        XCTAssertEqual(parts(result.date).hour, 12)
    }

    // MARK: Время по умолчанию

    /// Напоминание без времени переносится на утро, а не срабатывает сразу.
    func testNormalizedFireDateUsesDefaultHour() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "завтра купить билеты", context: context))
        let fireDate = DateExtractor.normalizedFireDate(from: result, context: context)

        let components = parts(fireDate)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, DateExtractor.defaultHour)
    }

    /// Время по умолчанию в прошлом переносится на следующий день:
    /// напоминание, которое уже просрочено, не сработает никогда.
    func testNormalizedFireDateSkipsPastTime() throws {
        let result = try XCTUnwrap(DateExtractor.extract(from: "сегодня заплатить", context: context))
        let fireDate = DateExtractor.normalizedFireDate(from: result, context: context)

        XCTAssertGreaterThan(fireDate, context.referenceDate)
    }

    func testReturnsNilWhenNoDate() {
        XCTAssertNil(DateExtractor.extract(from: "просто мысль про архитектуру", context: context))
    }
}
