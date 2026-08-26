import XCTest
@testable import AILifeAssistant

/// Каскад и слияние: самая хрупкая часть разбора, потому что от неё зависит,
/// обновится существующая запись или задвоится.
final class ParsingPipelineTests: XCTestCase {

    private var context: ParsingContext {
        ParsingContext(referenceDate: Date(timeIntervalSince1970: 1_787_000_000), languageCode: "ru-RU")
    }

    /// Потокобезопасный держатель предварительного результата.
    private final class PreliminaryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ParsedIntent?

        var value: ParsedIntent? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ intent: ParsedIntent) {
            lock.lock()
            stored = intent
            lock.unlock()
        }
    }

    /// Движок, возвращающий заранее заданный результат.
    private struct StubParser: IntentParsing {
        let engine: ParsingEngine
        let requiresNetwork: Bool
        let available: Bool
        let result: ParsedIntent?
        let error: ParsingError?

        var isAvailable: Bool { get async { available } }

        func parse(text: String, context: ParsingContext) async throws -> ParsedIntent {
            if let error { throw error }
            guard let result else { throw ParsingError.invalidResponse("нет данных") }
            return result
        }
    }

    private func intent(
        engine: ParsingEngine,
        items: [ParsedItem],
        confidence: Double = 0.9
    ) -> ParsedIntent {
        ParsedIntent(items: items, confidence: confidence, engine: engine)
    }

    // MARK: Каскад

    /// Предварительный результат приходит до того, как отработают модели.
    func testPreliminaryResultIsReportedBeforeRefinement() async throws {
        let cloudItem = ParsedItem(kind: .task, title: "Из облака", confidence: 0.95)

        let pipeline = ParsingPipeline(
            fastPath: FastPathParser(),
            localModel: nil,
            cloud: StubParser(
                engine: .cloud,
                requiresNetwork: true,
                available: true,
                result: intent(engine: .cloud, items: [cloudItem]),
                error: nil
            )
        )

        // Результат кладётся в потокобезопасный ящик: колбэк вызывается
        // из конкурентного контекста, и прямая запись в локальную переменную
        // в Swift 6 станет ошибкой.
        let box = PreliminaryBox()
        let outcome = try await pipeline.run(
            text: "нужно заказать воду",
            context: context,
            onPreliminary: { box.set($0) }
        )

        XCTAssertEqual(box.value?.engine, .fastPath)
        XCTAssertEqual(outcome.final.engine, .cloud)
        XCTAssertEqual(outcome.enginesUsed, [.fastPath, .cloud])
    }

    /// Отказ модели не должен ронять разбор: результат правил остаётся.
    func testCloudFailureKeepsFastPathResult() async throws {
        let pipeline = ParsingPipeline(
            fastPath: FastPathParser(),
            localModel: nil,
            cloud: StubParser(
                engine: .cloud,
                requiresNetwork: true,
                available: true,
                result: nil,
                error: .network("нет соединения")
            )
        )

        let outcome = try await pipeline.run(text: "купил кофе за 300 рублей", context: context)

        XCTAssertEqual(outcome.final.engine, .fastPath)
        XCTAssertEqual(outcome.enginesUsed, [.fastPath])
        XCTAssertFalse(outcome.final.items.isEmpty)
    }

    /// Недоступный движок просто пропускается.
    func testUnavailableEngineIsSkipped() async throws {
        let pipeline = ParsingPipeline(
            fastPath: FastPathParser(),
            localModel: StubParser(
                engine: .foundationModels,
                requiresNetwork: false,
                available: false,
                result: intent(engine: .foundationModels, items: []),
                error: nil
            ),
            cloud: nil
        )

        let outcome = try await pipeline.run(text: "нужно позвонить", context: context)
        XCTAssertEqual(outcome.enginesUsed, [.fastPath])
    }

    // MARK: Слияние

    /// Результат более авторитетного движка побеждает.
    func testMergePrefersHigherAuthority() {
        let base = intent(
            engine: .fastPath,
            items: [ParsedItem(kind: .task, title: "Правила", confidence: 0.6)]
        )
        let refined = intent(
            engine: .cloud,
            items: [ParsedItem(kind: .task, title: "Облако", confidence: 0.95)]
        )

        let merged = ParsingPipeline.merge(base: base, refined: refined)
        XCTAssertEqual(merged.engine, .cloud)
        XCTAssertEqual(merged.items.first?.title, "Облако")
    }

    /// Менее авторитетный результат не затирает лучший.
    func testMergeIgnoresLowerAuthority() {
        let base = intent(
            engine: .cloud,
            items: [ParsedItem(kind: .task, title: "Облако", confidence: 0.95)]
        )
        let refined = intent(
            engine: .fastPath,
            items: [ParsedItem(kind: .task, title: "Правила", confidence: 0.6)]
        )

        let merged = ParsingPipeline.merge(base: base, refined: refined)
        XCTAssertEqual(merged.items.first?.title, "Облако")
    }

    /// Ключевое свойство: совпавшая сущность сохраняет идентификатор,
    /// иначе уточнение создаст вторую такую же запись.
    func testMergeKeepsIdentifierForSameExpense() {
        let baseItem = ParsedItem(kind: .expense, title: "Кофе", amount: 300, confidence: 0.7)
        let refinedItem = ParsedItem(
            kind: .expense,
            title: "Кофе в кофейне",
            amount: 300,
            merchant: "Skuratov",
            confidence: 0.95
        )

        let merged = ParsingPipeline.merge(
            base: intent(engine: .fastPath, items: [baseItem]),
            refined: intent(engine: .cloud, items: [refinedItem])
        )

        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.items.first?.id, baseItem.id, "Идентификатор должен сохраниться")
        XCTAssertEqual(merged.items.first?.merchant, "Skuratov", "Уточнение должно примениться")
    }

    /// Разные суммы это разные траты, идентификатор переносить нельзя.
    func testMergeTreatsDifferentAmountsAsDifferentEntities() {
        let baseItem = ParsedItem(kind: .expense, title: "Кофе", amount: 300, confidence: 0.7)
        let refinedItem = ParsedItem(kind: .expense, title: "Кофе", amount: 450, confidence: 0.95)

        let merged = ParsingPipeline.merge(
            base: intent(engine: .fastPath, items: [baseItem]),
            refined: intent(engine: .cloud, items: [refinedItem])
        )

        XCTAssertNotEqual(merged.items.first?.id, baseItem.id)
    }

    /// Напоминания сопоставляются по времени с точностью до часа.
    func testMergeMatchesRemindersByTime() {
        let date = Date(timeIntervalSince1970: 1_787_100_000)
        let baseItem = ParsedItem(kind: .reminder, title: "Позвонить", dueDate: date, confidence: 0.7)
        let refinedItem = ParsedItem(
            kind: .reminder,
            title: "Позвонить в банк",
            dueDate: date.addingTimeInterval(600),
            confidence: 0.95
        )

        let merged = ParsingPipeline.merge(
            base: intent(engine: .fastPath, items: [baseItem]),
            refined: intent(engine: .cloud, items: [refinedItem])
        )

        XCTAssertEqual(merged.items.first?.id, baseItem.id)
    }

    /// Задачи сопоставляются по общим значимым словам заголовка.
    func testMergeMatchesTasksByTitleOverlap() {
        let baseItem = ParsedItem(kind: .task, title: "заказать воду домой", confidence: 0.6)
        let refinedItem = ParsedItem(kind: .task, title: "Заказать воду", confidence: 0.9)

        let merged = ParsingPipeline.merge(
            base: intent(engine: .fastPath, items: [baseItem]),
            refined: intent(engine: .cloud, items: [refinedItem])
        )

        XCTAssertEqual(merged.items.first?.id, baseItem.id)
    }

    func testMergeIgnoresEmptyRefinement() {
        let base = intent(
            engine: .fastPath,
            items: [ParsedItem(kind: .note, title: "Мысль", confidence: 0.5)]
        )
        let merged = ParsingPipeline.merge(base: base, refined: intent(engine: .cloud, items: []))

        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.engine, .fastPath)
    }
}
