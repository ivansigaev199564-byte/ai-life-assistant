import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Последние пять мест, которые аудит нашёл, а закрыть сразу не вышло.
@MainActor
final class RemainingFixesTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

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

    // MARK: Исправление суммы

    /// Правка суммы подменяла число прямо в сказанном, подстрокой:
    /// во фразе «взял 2 по 46» замена сорока шести задевала и соседнее
    /// число, а запись начинала врать о том, что человек произнёс.
    func testAmountCorrectionKeepsOriginalText() throws {
        let capture = CaptureItem(text: "взял 2 по 46")
        context.insert(capture)
        context.insert(Expense(amount: 46, source: capture))
        try context.save()

        let applier = CorrectionApplier(modelContext: context)
        _ = applier.apply(
            CorrectionDetector.Correction(target: .amount(64), confidence: 0.9, matchedText: "64")
        )

        XCTAssertEqual(capture.text, "взял 2 по 46", "Сказанное правке не подлежит")
        XCTAssertEqual(capture.expenses.first?.amount, 64)
        XCTAssertEqual(capture.expenses.first?.isUserEdited, true)
    }

    /// Раньше исправление держалось только на переписанном тексте: без него
    /// повторный разбор возвращал старую сумму. Теперь держится на пометке.
    func testReparsingDoesNotOverwriteUserEdit() async throws {
        let queue = ProcessingQueue(modelContext: context, pipeline: ParsingPipeline())

        let capture = CaptureItem(text: "купил кофе за 46 рублей")
        context.insert(capture)
        try context.save()
        await queue.processPending()

        let expense = try XCTUnwrap(capture.expenses.first)
        expense.amount = 64
        expense.isUserEdited = true
        try context.save()

        await queue.retry(capture)

        XCTAssertEqual(capture.expenses.first?.amount, 64, "Разбор не должен спорить с человеком")
    }

    // MARK: Имена

    func testDictionarySeparatesCloseNames() {
        XCTAssertFalse(Person(name: "Даня").matches("Дана"))
        XCTAssertFalse(Person(name: "Марк").matches("Мара"))
        XCTAssertFalse(Person(name: "Дана").matches("Даня"))
    }

    func testDictionaryKeepsCases() {
        XCTAssertTrue(Person(name: "Миша").matches("Мише"))
        XCTAssertTrue(Person(name: "Миша").matches("Михаилу"))
        XCTAssertTrue(Person(name: "Серёжа").matches("Сереже"))
    }

    /// «Дане» это и Дана, и Даня: словарь честно говорит «может быть»,
    /// а не выбирает наугад.
    func testAmbiguousFormMatchesBoth() {
        XCTAssertTrue(Person(name: "Дана").matches("Дане"))
        XCTAssertTrue(Person(name: "Даня").matches("Дане"))
    }

    func testUnknownNamesStillCompareByStem() {
        XCTAssertTrue(Person(name: "Вазген").matches("Вазгену"))
        XCTAssertFalse(Person(name: "Вазген").matches("Тигран"))
    }

    // MARK: Шумное место

    /// Автоматически отличить ровный шум от ровной речи по уровню нельзя,
    /// поэтому решение принимает человек, а приложение честно поднимает
    /// пороги.
    func testNoisyModeRaisesThresholds() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)

        let quiet = settings.vadConfiguration
        settings.isNoisyEnvironment = true
        let noisy = settings.vadConfiguration

        XCTAssertGreaterThan(noisy.speechThreshold, quiet.speechThreshold)
        XCTAssertGreaterThan(noisy.silenceThreshold, quiet.silenceThreshold)
        XCTAssertLessThan(noisy.silenceThreshold, noisy.speechThreshold, "Гистерезис должен сохраниться")
    }

    func testNoisyModeStopsOnStreetNoise() {
        var configuration = VoiceActivityDetector.Configuration.default
        configuration.speechThreshold *= 2.5
        configuration.silenceThreshold *= 2.5

        var detector = VoiceActivityDetector(configuration: configuration)
        var timestamp: TimeInterval = 0

        // Речь на улице: заметно громче фона.
        for _ in 0..<30 {
            _ = detector.process(level: 0.12, timestamp: timestamp)
            timestamp += 0.05
        }

        // Человек замолчал, остался шум улицы.
        var decision: VoiceActivityDetector.Decision = .speaking
        for _ in 0..<60 {
            decision = detector.process(level: 0.02, timestamp: timestamp)
            timestamp += 0.05
            if case .stop = decision { break }
        }

        guard case .stop(let reason) = decision else {
            return XCTFail("Автостоп не сработал, получено \(decision)")
        }
        XCTAssertEqual(reason, .silence)
    }
}
