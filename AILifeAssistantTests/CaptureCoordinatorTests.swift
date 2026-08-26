import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Проверяем то, что можно проверить без микрофона: текстовый захват,
/// защиту от пустого ввода и состояние координатора.
@MainActor
final class CaptureCoordinatorTests: XCTestCase {

    private var environment: AppEnvironment.Testing!

    override func setUp() async throws {
        try await super.setUp()
        environment = AppEnvironment.makeForTesting()
    }

    override func tearDown() async throws {
        environment = nil
        try await super.tearDown()
    }

    func testInitialPhaseIsIdle() {
        XCTAssertEqual(environment.coordinator.phase, .idle)
        XCTAssertFalse(environment.coordinator.phase.isActive)
        XCTAssertEqual(environment.coordinator.audioLevel, 0)
        XCTAssertTrue(environment.coordinator.liveTranscript.isEmpty)
    }

    func testSaveTextCaptureCreatesPendingItem() throws {
        let capture = environment.coordinator.saveTextCapture("Купить билеты в Тбилиси")

        let saved = try XCTUnwrap(capture)
        XCTAssertEqual(saved.status, .pending)
        XCTAssertEqual(saved.source, .manualText)
        XCTAssertEqual(saved.engine, .none)
        XCTAssertEqual(saved.recognitionConfidence, 1)

        let stored = try environment.container.mainContext.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.text, "Купить билеты в Тбилиси")
    }

    /// Пустая строка и пробелы не должны засорять инбокс.
    func testSaveTextCaptureIgnoresBlankInput() throws {
        XCTAssertNil(environment.coordinator.saveTextCapture(""))
        XCTAssertNil(environment.coordinator.saveTextCapture("    \n  "))

        let stored = try environment.container.mainContext.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertTrue(stored.isEmpty)
    }

    func testSaveTextCaptureTrimsWhitespace() throws {
        let capture = try XCTUnwrap(environment.coordinator.saveTextCapture("  идея приложения \n"))
        XCTAssertEqual(capture.text, "идея приложения")
    }

    /// Обработчик сохранения понадобится Этапу 2 для запуска разбора.
    func testOnCaptureSavedCallbackFires() throws {
        var received: CaptureItem?
        environment.coordinator.onCaptureSaved = { received = $0 }

        _ = environment.coordinator.saveTextCapture("Напомни позвонить в банк")

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.text, "Напомни позвонить в банк")
    }

    /// Остановка без активной сессии не должна ничего ломать.
    func testStopWithoutSessionIsSafe() async {
        await environment.coordinator.stop(reason: .manual)
        XCTAssertEqual(environment.coordinator.phase, .idle)
    }

    func testCancelWithoutSessionIsSafe() async {
        await environment.coordinator.cancel()
        XCTAssertEqual(environment.coordinator.phase, .idle)
    }

    // MARK: Настройки

    func testDictationModeSwitchesVADProfile() {
        let settings = environment.settings
        settings.isDictationMode = false
        XCTAssertEqual(settings.vadConfiguration.silenceDuration, VoiceActivityDetector.Configuration.default.silenceDuration)

        settings.isDictationMode = true
        XCTAssertEqual(settings.vadConfiguration.silenceDuration, VoiceActivityDetector.Configuration.dictation.silenceDuration)
        XCTAssertGreaterThan(settings.vadConfiguration.maximumDuration, 60)
    }
}
