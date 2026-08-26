import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Материализация: разбор превращается в записи и обновляет их при уточнении.
@MainActor
final class EntityMaterializerTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var materializer: EntityMaterializer!
    private var capture: CaptureItem!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        materializer = EntityMaterializer(modelContext: context)

        capture = CaptureItem(text: "купил кофе за 300 и напомни позвонить маме")
        context.insert(capture)
    }

    override func tearDownWithError() throws {
        capture = nil
        materializer = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    private func intent(_ items: [ParsedItem], engine: ParsingEngine = .fastPath) -> ParsedIntent {
        ParsedIntent(items: items, confidence: 0.9, engine: engine)
    }

    // MARK: Создание

    func testCreatesExpense() throws {
        let item = ParsedItem(
            kind: .expense,
            title: "Кофе",
            amount: 300,
            currencyCode: "RUB",
            category: .food,
            confidence: 0.9
        )

        let result = materializer.materialize(intent([item]), for: capture)

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(capture.expenses.count, 1)
        XCTAssertEqual(capture.expenses.first?.amount, 300)
        XCTAssertEqual(capture.expenses.first?.category, .food)
        XCTAssertEqual(capture.status, .synced)
    }

    /// Главный сценарий ТЗ: одна фраза порождает две разные сущности.
    func testCreatesMultipleEntitiesFromSingleCapture() throws {
        let expense = ParsedItem(kind: .expense, title: "Кофе", amount: 300, confidence: 0.9)
        let reminder = ParsedItem(
            kind: .reminder,
            title: "Позвонить маме",
            dueDate: .now.addingTimeInterval(3600),
            confidence: 0.85
        )

        let result = materializer.materialize(intent([expense, reminder]), for: capture)

        XCTAssertEqual(result.created, 2)
        XCTAssertEqual(capture.expenses.count, 1)
        XCTAssertEqual(capture.reminders.count, 1)
        XCTAssertEqual(capture.derivedItemsCount, 2)
    }

    // MARK: Идемпотентность

    /// Повторная материализация того же элемента обновляет запись,
    /// а не создаёт вторую: на этом держится каскад из трёх движков.
    func testSecondPassUpdatesInsteadOfDuplicating() throws {
        var item = ParsedItem(kind: .expense, title: "Кофе", amount: 300, confidence: 0.75)
        _ = materializer.materialize(intent([item]), for: capture)
        XCTAssertEqual(capture.expenses.count, 1)

        // Тот же элемент, уточнённый облаком: идентификатор сохранён.
        item.merchant = "Skuratov"
        item.confidence = 0.95
        let result = materializer.materialize(intent([item], engine: .cloud), for: capture)

        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.created, 0)
        XCTAssertEqual(capture.expenses.count, 1, "Дубль создаваться не должен")
        XCTAssertEqual(capture.expenses.first?.merchant, "Skuratov")
    }

    // MARK: Порог уверенности

    /// Ниже порога сущность не создаётся: сказанное сохраняется заметкой
    /// с пометкой на проверку.
    func testLowConfidenceBecomesReviewNote() throws {
        let item = ParsedItem(
            kind: .task,
            title: "Что-то неразборчивое",
            confidence: 0.4,
            sourceText: "мутная фраза"
        )

        let result = materializer.materialize(intent([item]), for: capture)

        XCTAssertEqual(result.flaggedForReview, 1)
        XCTAssertEqual(result.created, 0)
        XCTAssertTrue(capture.tasks.isEmpty, "Неуверенная задача создаваться не должна")

        let note = try XCTUnwrap(capture.notes.first)
        XCTAssertTrue(note.needsReview)
        XCTAssertTrue(note.tags.contains(EntityMaterializer.reviewTag))
    }

    /// Ровно на пороге сущность уже создаётся.
    func testConfidenceAtThresholdCreatesEntity() throws {
        let item = ParsedItem(
            kind: .task,
            title: "На границе",
            confidence: EntityMaterializer.confidenceThreshold
        )

        let result = materializer.materialize(intent([item]), for: capture)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(capture.tasks.count, 1)
    }

    /// Бессмысленные элементы отбрасываются: расход без суммы это не расход.
    func testInvalidItemsAreDiscarded() throws {
        let item = ParsedItem(kind: .expense, title: "Без суммы", confidence: 0.95)

        let result = materializer.materialize(intent([item]), for: capture)

        XCTAssertEqual(result.discarded, 1)
        XCTAssertEqual(result.created, 0)
        XCTAssertEqual(capture.status, .failed)
    }

    // MARK: Люди

    func testCreatesPersonAndLinksToEntity() throws {
        let item = ParsedItem(
            kind: .reminder,
            title: "Позвонить Мише",
            dueDate: .now.addingTimeInterval(3600),
            people: ["Миша"],
            confidence: 0.9
        )

        _ = materializer.materialize(
            ParsedIntent(items: [item], people: ["Миша"], confidence: 0.9, engine: .fastPath),
            for: capture
        )

        let people = try context.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.name, "Миша")
        XCTAssertEqual(capture.reminders.first?.people.count, 1)
    }

    /// Второе упоминание того же человека не должно заводить вторую карточку.
    func testReusesExistingPerson() throws {
        let existing = Person(name: "Миша")
        context.insert(existing)

        let item = ParsedItem(kind: .task, title: "Написать Мише", people: ["Мише"], confidence: 0.9)
        _ = materializer.materialize(
            ParsedIntent(items: [item], people: ["Мише"], confidence: 0.9, engine: .fastPath),
            for: capture
        )

        let people = try context.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(people.count, 1, "Падежная форма не должна создавать второго человека")
        XCTAssertEqual(people.first?.mentionCount, 1)
    }

    // MARK: Метаданные захвата

    func testCaptureRecordsParsingMetadata() throws {
        let item = ParsedItem(kind: .note, title: "Мысль", details: "текст", confidence: 0.9)
        _ = materializer.materialize(intent([item], engine: .foundationModels), for: capture)

        XCTAssertNotNil(capture.parsedAt)
        XCTAssertEqual(capture.parsingEngine, .foundationModels)
        XCTAssertEqual(capture.parseConfidence, 0.9, accuracy: 0.001)
        XCTAssertFalse(capture.needsReview)
    }
}
