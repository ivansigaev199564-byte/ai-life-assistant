import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Закрытие дела. Тесты держат ровно одно обещание: дело, отмеченное
/// выполненным, остаётся выполненным и о нём узнаёт синхронизация.
@MainActor
final class CompletionServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: CompletionService!
    private var changes: [(SyncEntityType, UUID)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        changes = []

        service = CompletionService(modelContext: context)
        service.onChanged = { [weak self] entityType, id in
            self?.changes.append((entityType, id))
        }
    }

    override func tearDownWithError() throws {
        service = nil
        context = nil
        container = nil
        changes = []
        try super.tearDownWithError()
    }

    // MARK: Задачи

    func testTogglesTask() throws {
        let task = TaskItem(title: "Заказать воду")
        context.insert(task)
        try context.save()

        service.toggle(task)

        XCTAssertTrue(task.isCompleted)
        XCTAssertNotNil(task.completedAt, "Время закрытия нужно разделу «Выполнено»")
        XCTAssertEqual(task.syncState, .pendingUpload)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, .task)
        XCTAssertEqual(changes.first?.1, task.id)
    }

    func testReturnsTaskToWork() throws {
        let task = TaskItem(title: "Заказать воду")
        context.insert(task)
        try context.save()

        service.toggle(task)
        service.toggle(task)

        XCTAssertFalse(task.isCompleted, "Промах по галочке должен отменяться так же легко")
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(changes.count, 2)
    }

    /// Отметка обязана пережить перезапуск: незакрытая задача, всплывшая
    /// снова, это худшее, что может случиться со списком дел.
    func testCompletionSurvivesNewContext() throws {
        let task = TaskItem(title: "Оплатить интернет")
        context.insert(task)
        try context.save()

        service.toggle(task)

        let fresh = ModelContext(container)
        let identifier = task.id
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == identifier })
        descriptor.fetchLimit = 1

        let stored = try XCTUnwrap(fresh.fetch(descriptor).first)
        XCTAssertTrue(stored.isCompleted)
    }

    // MARK: Напоминания

    func testTogglesReminder() throws {
        let reminder = Reminder(title: "Позвонить в банк", fireDate: .now.addingTimeInterval(3600))
        context.insert(reminder)
        try context.save()

        service.toggle(reminder)

        XCTAssertTrue(reminder.isCompleted)
        XCTAssertEqual(changes.first?.0, .reminder)
    }

    /// Повторный вызов с тем же значением не должен поднимать шум:
    /// иначе очередь синхронизации наполняется пустыми операциями.
    func testIgnoresRepeatedState() throws {
        let reminder = Reminder(title: "Забрать посылку", fireDate: .now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()

        service.setCompleted(true, for: reminder)
        service.setCompleted(true, for: reminder)

        XCTAssertEqual(changes.count, 1)
    }
}
