import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Поведение на объёме: выборки должны уходить в базу, а не подниматься
/// в память целиком. Тесты проверяют то, что можно проверить без профайлера:
/// работает ли условие как предикат и не теряется ли смысл.
@MainActor
final class ScaleTests: XCTestCase {

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

    // MARK: Требует проверки

    /// Условие «на проверку» живёт одним предикатом и должно отбирать
    /// ровно то же, что вычисляемое свойство модели.
    func testNeedsReviewPredicateMatchesModelRule() throws {
        let uncertain = CaptureItem(text: "неуверенный разбор")
        uncertain.parsedAt = .now
        uncertain.parseConfidence = 0.4

        let confident = CaptureItem(text: "уверенный разбор")
        confident.parsedAt = .now
        confident.parseConfidence = 0.9

        let unparsed = CaptureItem(text: "ещё не разобрано")

        for capture in [uncertain, confident, unparsed] {
            context.insert(capture)
        }
        try context.save()

        let found = try context.fetch(
            FetchDescriptor<CaptureItem>(predicate: CaptureItem.needsReviewPredicate)
        )

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "неуверенный разбор")

        // И то же самое по свойству модели: расхождение здесь означало бы,
        // что экран и выборка показывают разное.
        let all = try context.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertEqual(all.filter(\.needsReview).count, found.count)
    }

    // MARK: Поиск

    /// Поиск ищет по базе предикатом. Проверяем, что он вообще находит
    /// и что находит только подходящее.
    func testLocalSearchFindsByPredicate() async throws {
        let coffee = CaptureItem(text: "купил кофе за 300")
        let bank = CaptureItem(text: "позвонить в банк")
        context.insert(coffee)
        context.insert(bank)
        try context.save()

        let service = SearchService(modelContext: context, networkMonitor: NetworkMonitor())
        service.search("кофе")

        // Поиск отложен на четверть секунды: без паузы каждая буква
        // запускала полный проход по пяти таблицам.
        XCTAssertTrue(service.results.isEmpty, "Сразу после ввода результатов быть не должно")

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(service.results.count, 1)
        XCTAssertEqual(service.results.first?.kind, .capture)
        XCTAssertEqual(service.results.first?.id, coffee.id)
    }

    func testSearchClearsResults() async throws {
        let capture = CaptureItem(text: "купил кофе за 300")
        context.insert(capture)
        try context.save()

        let service = SearchService(modelContext: context, networkMonitor: NetworkMonitor())
        service.search("кофе")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(service.results.isEmpty)

        service.clear()
        XCTAssertTrue(service.results.isEmpty)
    }

    // MARK: Деньги

    /// Точность денег проверяется через диск: Decimal, сохранённый и
    /// прочитанный заново, обязан совпасть до копейки.
    func testDecimalSurvivesRoundTrip() throws {
        let amount = Decimal(string: "1234.56")!
        let expense = Expense(amount: amount, currencyCode: "RUB", category: .food)
        context.insert(expense)
        try context.save()

        let identifier = expense.id
        let fresh = ModelContext(container)
        var descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.id == identifier })
        descriptor.fetchLimit = 1

        let stored = try XCTUnwrap(fresh.fetch(descriptor).first)
        XCTAssertEqual(stored.amount, amount, "Копейки не должны теряться при сохранении")
    }
}
