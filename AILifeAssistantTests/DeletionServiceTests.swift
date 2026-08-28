import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Удаление. Проверяется главное: сервер узнаёт о том, что запись исчезла.
/// Без этого удалённое возвращалось после переустановки и жило на втором
/// устройстве вечно.
@MainActor
final class DeletionServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: DeletionService!
    private var deletions: [(SyncEntityType, UUID)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        deletions = []

        service = DeletionService(modelContext: context)
        service.onDeleted = { [weak self] entityType, id in
            self?.deletions.append((entityType, id))
        }
    }

    override func tearDownWithError() throws {
        service = nil
        context = nil
        container = nil
        deletions = []
        try super.tearDownWithError()
    }

    func testDeletesCaptureAndTellsSync() throws {
        let capture = CaptureItem(text: "купил кофе за 300")
        context.insert(capture)
        try context.save()

        XCTAssertTrue(service.delete(capture))

        XCTAssertTrue(try context.fetch(FetchDescriptor<CaptureItem>()).isEmpty)
        XCTAssertEqual(deletions.count, 1)
        XCTAssertEqual(deletions.first?.0, .capture)
        XCTAssertEqual(deletions.first?.1, capture.id)
    }

    /// Производные сущности уходят каскадом, но сервер о каскаде не знает:
    /// ему нужен список всего, что исчезло.
    func testReportsDerivedEntities() throws {
        let capture = CaptureItem(text: "купил кофе за 300 и напомни позвонить маме")
        context.insert(capture)

        let expense = Expense(amount: 300, currencyCode: "RUB", category: .food, source: capture)
        let task = TaskItem(title: "Позвонить маме", source: capture)
        context.insert(expense)
        context.insert(task)
        try context.save()

        service.delete(capture)

        let types = Set(deletions.map(\.0))
        XCTAssertTrue(types.contains(.capture))
        XCTAssertTrue(types.contains(.expense), "Расход тоже исчез, сервер должен узнать")
        XCTAssertTrue(types.contains(.task))
    }

    func testDeletesBatch() throws {
        let captures = (0..<3).map { CaptureItem(text: "запись \($0)") }
        captures.forEach(context.insert)
        try context.save()

        XCTAssertEqual(service.delete(captures), 3)
        XCTAssertEqual(deletions.count, 3)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CaptureItem>()).isEmpty)
    }

    func testDeletesProject() throws {
        let project = Project(name: "Ремонт")
        context.insert(project)
        try context.save()

        XCTAssertTrue(service.delete(project))
        XCTAssertEqual(deletions.first?.0, .project)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).isEmpty)
    }

    func testEmptyBatchDoesNothing() {
        XCTAssertEqual(service.delete([]), 0)
        XCTAssertTrue(deletions.isEmpty)
    }
}
