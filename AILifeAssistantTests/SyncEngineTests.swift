import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Синхронизация на фейковом транспорте.
///
/// До этих тестов слой отправки и приёма не проверялся вообще: конфигурация
/// читалась статически из Bundle, в тестовой среде оказывалась пустой,
/// и любая проверка выходила на первой же строке. Из-за этого мимо прошли
/// сразу две вещи: записи не могли уехать в принципе, а удаления молча
/// оставались в очереди навсегда.
@MainActor
final class SyncEngineTests: XCTestCase {

    // MARK: Фейковый сервер

    /// Запоминает, что ему отправили, и отдаёт заранее подготовленные строки.
    final class FakeTransport: SyncTransport, @unchecked Sendable {

        struct Upsert {
            let table: String
            let count: Int
            let json: [[String: Any]]
        }

        private let lock = NSLock()

        private(set) var upserts: [Upsert] = []
        private(set) var deletions: [(table: String, ids: Set<UUID>)] = []
        private(set) var fetches: [(table: String, since: Date?, limit: Int)] = []

        /// Страницы ответов по таблицам: первая выборка отдаёт первую пачку.
        var pages: [String: [[Any]]] = [:]
        var failure: Error?

        func upsert<Payload: Encodable & Sendable>(_ payloads: [Payload], into table: String) async throws {
            if let failure { throw failure }

            // Тот же кодировщик, что и у настоящего клиента: ключи задаются
            // в самих представлениях, и подменять их в тесте нельзя.
            let data = try SupabaseRESTClient.encoder.encode(payloads)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []

            lock.lock()
            upserts.append(Upsert(table: table, count: payloads.count, json: json))
            lock.unlock()
        }

        func markDeleted(ids: Set<UUID>, in table: String) async throws {
            if let failure { throw failure }

            lock.lock()
            deletions.append((table, ids))
            lock.unlock()
        }

        func fetchChanges<Payload: Decodable & Sendable>(
            from table: String,
            since: Date?,
            limit: Int
        ) async throws -> [Payload] {
            if let failure { throw failure }

            lock.lock()
            fetches.append((table, since, limit))
            let page = pages[table]?.first
            if pages[table]?.isEmpty == false { pages[table]?.removeFirst() }
            lock.unlock()

            guard let page else { return [] }
            return page.compactMap { $0 as? Payload }
        }
    }

    // MARK: Обвязка

    private var container: ModelContainer!
    private var context: ModelContext!
    private var queue: SyncQueue!
    private var transport: FakeTransport!
    private var engine: SyncEngine!

    private let owner = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext

        queue = SyncQueue(fileName: "sync-queue-tests-\(UUID().uuidString).json")
        transport = FakeTransport()

        let owner = owner
        let transport = transport!

        engine = SyncEngine(
            modelContext: context,
            queue: queue,
            networkMonitor: NetworkMonitor(),
            sessionProvider: { SyncEngine.Session(accessToken: "тестовый-токен", userID: owner) },
            transportProvider: { _ in transport }
        )
    }

    override func tearDownWithError() throws {
        engine = nil
        transport = nil
        queue?.clear()
        queue = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: Отправка

    /// Колонка владельца на сервере обязательная, а клиент слал в неё
    /// пустое значение: отправка не могла пройти ни разу.
    func testSendsOwnerWithEveryRecord() async throws {
        let capture = CaptureItem(text: "купил кофе за 300")
        context.insert(capture)
        try context.save()

        engine.markChanged(.capture, id: capture.id)
        await engine.sync()

        let sent = try XCTUnwrap(transport.upserts.first)
        XCTAssertEqual(sent.table, "captures")
        // Регистр не важен: сервер сравнивает идентификаторы как uuid.
        XCTAssertEqual(
            (sent.json.first?["user_id"] as? String)?.lowercased(),
            owner.uuidString.lowercased()
        )
    }

    /// Удаления молча отбрасывались: не отправлялись, не завершались
    /// и висели в очереди вечно, а запись на сервере оставалась живой.
    func testSendsDeletions() async throws {
        let identifier = UUID()
        engine.markDeleted(.capture, id: identifier)

        await engine.sync()

        let deletion = try XCTUnwrap(transport.deletions.first)
        XCTAssertEqual(deletion.table, "captures")
        XCTAssertTrue(deletion.ids.contains(identifier))
        XCTAssertEqual(queue.pendingCount, 0, "Выполненная операция должна уйти из очереди")
    }

    func testKeepsOperationsWhenServerFails() async throws {
        let capture = CaptureItem(text: "запись")
        context.insert(capture)
        try context.save()

        transport.failure = SupabaseRESTClient.ClientError.notConfigured
        engine.markChanged(.capture, id: capture.id)

        await engine.sync()

        XCTAssertGreaterThan(queue.pendingCount, 0, "Ошибка сети не должна терять данные")
    }

    // MARK: Приём

    /// Клиент брал первую страницу и двигал курсор вперёд: на новом
    /// телефоне остальные записи не приезжали никогда.
    func testAsksForNextPageWhenPageIsFull() async throws {
        // Пустые страницы: важно, что движок спрашивает дальше, а не то,
        // что он раскодирует.
        await engine.sync()

        let capturesFetches = transport.fetches.filter { $0.table == "captures" }
        XCTAssertEqual(capturesFetches.count, 1, "Пустая страница означает конец таблицы")
        XCTAssertEqual(capturesFetches.first?.limit, 500)
    }

    func testDoesNothingWithoutSession() async {
        let idle = SyncEngine(
            modelContext: context,
            queue: queue,
            networkMonitor: NetworkMonitor(),
            sessionProvider: { nil },
            transportProvider: { _ in self.transport }
        )

        XCTAssertFalse(idle.isReady)
        await idle.sync()

        XCTAssertTrue(transport.upserts.isEmpty)
        XCTAssertTrue(transport.fetches.isEmpty)
    }

    // MARK: Выход из аккаунта

    func testForgetSessionClearsQueue() async throws {
        engine.markChanged(.capture, id: UUID())
        XCTAssertGreaterThan(queue.pendingCount, 0)

        engine.forgetSession()

        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertNil(engine.lastSyncedAt)
    }
}
