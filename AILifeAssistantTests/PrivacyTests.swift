import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Приватность: обещание «всё остаётся у вас» должно держаться на коде,
/// а не на настройках по умолчанию.
@MainActor
final class PrivacyTests: XCTestCase {

    // MARK: Выгрузка

    /// Поле, начинающееся со знака равенства, Excel исполняет как формулу.
    /// Текст в выгрузке приходит из распознавания речи, то есть снаружи.
    func testCSVNeutralizesFormulas() {
        XCTAssertEqual(ExportService.escape("=1+1"), "'=1+1")
        XCTAssertEqual(ExportService.escape("+79001234567"), "'+79001234567")
        XCTAssertEqual(ExportService.escape("-5"), "'-5")
        XCTAssertEqual(ExportService.escape("@SUM(A1)"), "'@SUM(A1)")
    }

    func testCSVStillEscapesOrdinaryFields() {
        XCTAssertEqual(ExportService.escape("кофе"), "кофе")
        XCTAssertEqual(ExportService.escape("кофе, чай"), "\"кофе, чай\"")
        XCTAssertEqual(ExportService.escape("он сказал \"да\""), "\"он сказал \"\"да\"\"\"")
    }

    /// Выгрузка не должна оставаться на диске: это полный дамп дневника.
    func testExportCleansPreviousFiles() throws {
        let directory = try ExportService.exportDirectory()
        let stale = directory.appendingPathComponent("ai-assistant-2020-01-01.json")
        try Data("старая выгрузка".utf8).write(to: stale)

        ExportService.removeStaleExports()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale.path),
            "Прошлая выгрузка должна исчезнуть"
        )
    }

    // MARK: Сеть

    /// Ответы сервера содержат тексты записей и суммы трат. Общий дисковый
    /// кэш URLSession.shared хранил их открытым текстом и не чистился
    /// при выходе из аккаунта.
    func testNetworkSessionDoesNotCacheToDisk() {
        let configuration = PrivateSession.shared.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    // MARK: Замок

    func testAppLockStartsLockedWhenEnabled() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "security.appLock.enabled")

        let lock = AppLock(defaults: defaults)

        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(lock.isLocked, "Записи не должны мелькнуть до проверки")
    }

    func testAppLockStaysOpenWhenDisabled() {
        let lock = AppLock(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)

        lock.applicationDidEnterBackground(at: .now.addingTimeInterval(-3600))
        lock.applicationWillEnterForeground()

        XCTAssertFalse(lock.isLocked, "Выключенный замок не запирает")
    }

    /// Мгновенная блокировка мешает: между записью голоса и ответом
    /// на звонок проходит несколько секунд.
    func testAppLockKeepsGracePeriod() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let lock = AppLock(defaults: defaults)
        lock.isEnabled = true

        let left = Date(timeIntervalSince1970: 1_787_000_000)
        lock.applicationDidEnterBackground(at: left)
        lock.applicationWillEnterForeground(at: left.addingTimeInterval(5))

        XCTAssertFalse(lock.isLocked, "Пять секунд в фоне это не повод запирать")

        lock.applicationDidEnterBackground(at: left)
        lock.applicationWillEnterForeground(at: left.addingTimeInterval(AppLock.grace + 1))

        XCTAssertTrue(lock.isLocked, "Через минуту приложение запирается")
    }
}
