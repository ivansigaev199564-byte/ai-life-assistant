import Foundation
import XCTest
@testable import AILifeAssistant

/// Очередь синхронизации: от неё зависит, потеряются ли данные,
/// созданные без сети.
@MainActor
final class SyncQueueTests: XCTestCase {

    private var queue: SyncQueue!
    private var fileName: String!

    override func setUp() async throws {
        try await super.setUp()
        // Отдельный файл на каждый тест: очередь переживает перезапуск,
        // и общий файл склеил бы тесты между собой.
        fileName = "sync-queue-test-\(UUID().uuidString).json"
        queue = SyncQueue(fileName: fileName)
    }

    override func tearDown() async throws {
        queue.clear()
        queue = nil
        try await super.tearDown()
    }

    func testEnqueueAddsOperation() {
        let id = UUID()
        queue.enqueue(.capture, id: id, kind: .upsert)

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.operations.first?.entityID, id)
        XCTAssertEqual(queue.operations.first?.kind, .upsert)
    }

    /// Повторная постановка той же записи заменяет прежнюю: отправлять
    /// одну сущность дважды бессмысленно, уедет её текущее состояние.
    func testEnqueueReplacesDuplicate() {
        let id = UUID()
        queue.enqueue(.note, id: id, kind: .upsert)
        queue.enqueue(.note, id: id, kind: .upsert)
        queue.enqueue(.note, id: id, kind: .delete)

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.operations.first?.kind, .delete)
    }

    /// Разные типы с одинаковым идентификатором это разные операции.
    func testDifferentTypesCoexist() {
        let id = UUID()
        queue.enqueue(.note, id: id, kind: .upsert)
        queue.enqueue(.task, id: id, kind: .upsert)

        XCTAssertEqual(queue.pendingCount, 2)
    }

    func testCompleteRemovesOperation() throws {
        queue.enqueue(.expense, id: UUID(), kind: .upsert)
        let operation = try XCTUnwrap(queue.operations.first)

        queue.complete(operation)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testFailIncrementsAttempts() throws {
        queue.enqueue(.capture, id: UUID(), kind: .upsert)
        let operation = try XCTUnwrap(queue.operations.first)

        queue.fail(operation)
        XCTAssertEqual(queue.operations.first?.attempts, 1)

        queue.fail(operation)
        XCTAssertEqual(queue.operations.first?.attempts, 2)
    }

    /// Операция, исчерпавшая попытки, перестаёт выдаваться на отправку,
    /// но остаётся в очереди: данные не теряются.
    func testExhaustedOperationIsNotOffered() throws {
        queue.enqueue(.capture, id: UUID(), kind: .upsert)
        let operation = try XCTUnwrap(queue.operations.first)

        for _ in 0..<SyncQueue.maxAttempts {
            queue.fail(operation)
        }

        XCTAssertTrue(queue.next().isEmpty)
        XCTAssertEqual(queue.pendingCount, 1, "Операция остаётся в очереди")
    }

    /// После восстановления связи счётчики сбрасываются: прошлые неудачи
    /// были вызваны отсутствием сети, а не содержимым записей.
    func testResetAttemptsRevivesOperations() throws {
        queue.enqueue(.capture, id: UUID(), kind: .upsert)
        let operation = try XCTUnwrap(queue.operations.first)

        for _ in 0..<SyncQueue.maxAttempts {
            queue.fail(operation)
        }
        XCTAssertTrue(queue.next().isEmpty)

        queue.resetAttempts()
        XCTAssertEqual(queue.next().count, 1)
    }

    /// Очередь обязана пережить перезапуск приложения.
    func testQueueSurvivesRestart() {
        let id = UUID()
        queue.enqueue(.reminder, id: id, kind: .upsert)

        let restored = SyncQueue(fileName: fileName)

        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(restored.operations.first?.entityID, id)
        restored.clear()
    }

    func testNextRespectsOrderAndLimit() {
        for _ in 0..<5 {
            queue.enqueue(.note, id: UUID(), kind: .upsert)
        }

        let batch = queue.next(limit: 3)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch, batch.sorted { $0.queuedAt < $1.queuedAt })
    }

    func testTableNamesMatchSchema() {
        XCTAssertEqual(SyncEntityType.capture.tableName, "captures")
        XCTAssertEqual(SyncEntityType.person.tableName, "people")
        XCTAssertEqual(SyncEntityType.task.tableName, "tasks")
    }
}
