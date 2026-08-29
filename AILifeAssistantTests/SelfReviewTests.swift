import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Проверка кода, написанного во время работы над находками аудита.
///
/// Аудит читал прежний код, а за время правок его прибавилось заметно.
/// Эти тесты закрывают то, что нашлось при перечитывании собственных
/// изменений.
@MainActor
final class SelfReviewTests: XCTestCase {

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

    // MARK: Замок

    /// Устройство, которому нечем подтвердить личность.
    private struct UnavailableContext: AuthenticationContext {
        func canAuthenticate() -> Bool { false }
        func authenticate(reason: String) async throws -> Bool { false }
    }

    /// Устройство, где проверка проходит.
    private struct AcceptingContext: AuthenticationContext {
        func canAuthenticate() -> Bool { true }
        func authenticate(reason: String) async throws -> Bool { true }
    }

    /// Замок опирается на устройство. Если подтвердить личность нечем
    /// (код-пароль сняли, биометрия сломалась), запертым остаётся всё,
    /// включая настройки, где замок выключается. Выхода из положения
    /// не было бы вовсе.
    func testLockOpensWhenDeviceCannotVerify() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "security.appLock.enabled")

        let lock = AppLock(defaults: defaults) { UnavailableContext() }
        XCTAssertTrue(lock.isLocked)

        await lock.unlock()

        XCTAssertFalse(lock.isLocked, "Проверить нечем, держать запертым нельзя")
        XCTAssertFalse(lock.isEnabled, "Замок должен выключиться, а не спрашивать снова")
    }

    func testLockOpensAfterSuccessfulCheck() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "security.appLock.enabled")

        let lock = AppLock(defaults: defaults) { AcceptingContext() }
        XCTAssertTrue(lock.isLocked)

        await lock.unlock()

        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(lock.isEnabled, "Успешная проверка замок не выключает")
    }

    // MARK: Повторный разбор

    /// Сказанное изменилось, и часть прежних записей больше не нужна:
    /// «купил кофе за 300 и напомни позвонить» после правки превратилось
    /// в одну трату, а напоминание висело бы вечно.
    func testReparsingRemovesEntitiesThatNoLongerExist() async throws {
        let queue = ProcessingQueue(modelContext: context, pipeline: ParsingPipeline())

        let capture = CaptureItem(text: "купил кофе за 300 рублей и напомни завтра позвонить в банк")
        context.insert(capture)
        try context.save()
        await queue.processPending()

        XCTAssertFalse(capture.expenses.isEmpty, "Трата должна была появиться")
        XCTAssertFalse(capture.reminders.isEmpty, "Напоминание должно было появиться")

        // Человек поправил текст: половина фразы ушла.
        capture.text = "купил кофе за 300 рублей"
        capture.parsedAt = nil
        try context.save()

        await queue.retry(capture)

        XCTAssertEqual(capture.expenses.count, 1)
        XCTAssertTrue(
            capture.reminders.isEmpty,
            "Напоминание, которого больше нет во фразе, должно исчезнуть"
        )
    }

    /// Поправленное человеком не удаляется, даже если новый разбор его
    /// больше не видит: он уже один раз ошибся, а человек нет.
    func testReparsingKeepsUserEditedEntities() async throws {
        let queue = ProcessingQueue(modelContext: context, pipeline: ParsingPipeline())

        let capture = CaptureItem(text: "купил кофе за 300 рублей и напомни завтра позвонить в банк")
        context.insert(capture)
        try context.save()
        await queue.processPending()

        let reminder = try XCTUnwrap(capture.reminders.first)
        reminder.title = "Позвонить в банк по поводу карты"
        reminder.isUserEdited = true
        try context.save()

        capture.text = "купил кофе за 300 рублей"
        capture.parsedAt = nil
        try context.save()

        await queue.retry(capture)

        XCTAssertEqual(capture.reminders.count, 1, "Правка человека остаётся на месте")
        XCTAssertEqual(capture.reminders.first?.title, "Позвонить в банк по поводу карты")
    }

    // MARK: Объекты базы в задачах

    /// Закрытие дела ставит фоновую задачу на снятие уведомления. Если
    /// в неё передать сам объект, а запись к моменту выполнения удалить,
    /// приложение падает без возможности перехвата. Проверяем, что путь
    /// по идентификатору переживает исчезновение записи.
    func testCompletionSurvivesDeletedReminder() async throws {
        let notifications = NotificationService()
        let mirror = ReminderMirror(
            modelContext: context,
            notifications: notifications,
            eventKit: EventKitService(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let reminder = Reminder(title: "Позвонить", fireDate: .now.addingTimeInterval(3600))
        context.insert(reminder)
        try context.save()

        let identifier = reminder.id
        context.delete(reminder)
        try context.save()

        // Запись исчезла раньше, чем задача добралась до неё.
        await mirror.update(reminderID: identifier)
        await mirror.register(reminderID: identifier)
    }
}
