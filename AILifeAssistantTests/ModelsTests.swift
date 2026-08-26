import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Проверки схемы SwiftData: связи, каскады и переходы состояний.
@MainActor
final class ModelsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // База в памяти: тесты не трогают диск и не зависят друг от друга.
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: Захват

    func testCaptureStatusTransitions() throws {
        let capture = CaptureItem(text: "Купил кофе за 300 рублей", source: .actionButton)
        context.insert(capture)

        XCTAssertEqual(capture.status, .pending)
        XCTAssertEqual(capture.processingAttempts, 0)

        capture.markProcessing()
        XCTAssertEqual(capture.status, .processing)
        XCTAssertEqual(capture.processingAttempts, 1)

        capture.markFailed("нет сети")
        XCTAssertEqual(capture.status, .failed)
        XCTAssertEqual(capture.failureReason, "нет сети")

        capture.markSynced(remoteID: "srv-1")
        XCTAssertEqual(capture.status, .synced)
        XCTAssertNil(capture.failureReason)
        XCTAssertEqual(capture.remoteID, "srv-1")
        XCTAssertEqual(capture.syncState, .synced)
    }

    /// Один захват порождает несколько сущностей: это основной сценарий
    /// мульти-интента из ТЗ.
    func testCaptureHoldsMultipleDerivedItems() throws {
        let capture = CaptureItem(text: "Купил кофе за 300 и напомни позвонить маме")
        context.insert(capture)

        let expense = Expense(amount: 300, currencyCode: "RUB", category: .food, source: capture)
        let reminder = Reminder(title: "Позвонить маме", fireDate: .now.addingTimeInterval(3600), source: capture)
        context.insert(expense)
        context.insert(reminder)
        try context.save()

        XCTAssertEqual(capture.derivedItemsCount, 2)
        XCTAssertTrue(capture.hasDerivedItems)
    }

    /// Удаление захвата уносит порождённые сущности: иначе в базе
    /// остаются висячие записи без источника.
    func testDeletingCaptureCascadesToDerivedItems() throws {
        let capture = CaptureItem(text: "Заметка и задача")
        context.insert(capture)

        let note = Note(body: "Идея для приложения", source: capture)
        let task = TaskItem(title: "Прочитать статью", source: capture)
        context.insert(note)
        context.insert(task)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 1)

        context.delete(capture)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 0)
    }

    /// Удаление человека не должно удалять записи, в которых он упомянут.
    func testDeletingPersonKeepsRelatedItems() throws {
        let person = Person(name: "Миша")
        let task = TaskItem(title: "Позвонить Мише")
        context.insert(person)
        context.insert(task)
        task.people.append(person)
        try context.save()

        XCTAssertEqual(person.tasks.count, 1)

        context.delete(person)
        try context.save()

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1, "Задача должна пережить удаление человека")
        XCTAssertTrue(tasks[0].people.isEmpty)
    }

    // MARK: Задачи и напоминания

    func testTaskCompletionTogglesTimestamp() throws {
        let task = TaskItem(title: "Купить билеты")
        context.insert(task)

        XCTAssertFalse(task.isCompleted)
        XCTAssertNil(task.completedAt)

        task.toggleCompletion()
        XCTAssertTrue(task.isCompleted)
        XCTAssertNotNil(task.completedAt)

        task.toggleCompletion()
        XCTAssertFalse(task.isCompleted)
        XCTAssertNil(task.completedAt)
    }

    func testOverdueLogic() throws {
        let pastTask = TaskItem(title: "Просрочено", dueDate: .now.addingTimeInterval(-3600))
        let futureTask = TaskItem(title: "Впереди", dueDate: .now.addingTimeInterval(3600))
        let noDateTask = TaskItem(title: "Без срока")
        context.insert(pastTask)
        context.insert(futureTask)
        context.insert(noDateTask)

        XCTAssertTrue(pastTask.isOverdue)
        XCTAssertFalse(futureTask.isOverdue)
        XCTAssertFalse(noDateTask.isOverdue, "Без даты просрочки быть не может")

        pastTask.toggleCompletion()
        XCTAssertFalse(pastTask.isOverdue, "Закрытая задача не считается просроченной")
    }

    func testPriorityMapsToEventKitValues() {
        XCTAssertEqual(Priority.none.ekPriority, 0)
        XCTAssertEqual(Priority.high.ekPriority, 1)
        XCTAssertEqual(Priority.medium.ekPriority, 5)
        XCTAssertEqual(Priority.low.ekPriority, 9)
    }

    // MARK: Расходы

    /// Деньги хранятся в Decimal: на Double сумма 0.1 + 0.2 не даст 0.3.
    func testExpenseUsesDecimalArithmetic() throws {
        let first = Expense(amount: Decimal(string: "0.1")!, currencyCode: "USD")
        let second = Expense(amount: Decimal(string: "0.2")!, currencyCode: "USD")
        context.insert(first)
        context.insert(second)

        XCTAssertEqual(first.amount + second.amount, Decimal(string: "0.3")!)
    }

    // MARK: Люди и проекты

    func testPersonMatchesAliasesCaseInsensitively() {
        let person = Person(name: "Михаил", aliases: ["Миша", "Мише"])

        XCTAssertTrue(person.matches("михаил"))
        XCTAssertTrue(person.matches("Миша"))
        XCTAssertTrue(person.matches("  мише  "))
        XCTAssertFalse(person.matches("Ольга"))
    }

    func testProjectCountsOpenItems() throws {
        let project = Project(name: "Ремонт")
        context.insert(project)

        let openTask = TaskItem(title: "Выбрать плитку")
        let doneTask = TaskItem(title: "Замерить стены")
        context.insert(openTask)
        context.insert(doneTask)
        openTask.projects.append(project)
        doneTask.projects.append(project)
        doneTask.toggleCompletion()
        try context.save()

        XCTAssertEqual(project.itemsCount, 2)
        XCTAssertEqual(project.openItemsCount, 1)
    }

    // MARK: Запрос по статусу

    /// Перечисления хранятся строками именно ради работоспособных предикатов.
    func testFetchByStatusPredicate() throws {
        let pending = CaptureItem(text: "Первая", status: .pending)
        let failed = CaptureItem(text: "Вторая", status: .failed)
        context.insert(pending)
        context.insert(failed)
        try context.save()

        let all = try context.fetch(FetchDescriptor<CaptureItem>())
        let pendingOnly = all.filter { $0.status == .pending }

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(pendingOnly.count, 1)
        XCTAssertEqual(pendingOnly.first?.text, "Первая")
    }
}
