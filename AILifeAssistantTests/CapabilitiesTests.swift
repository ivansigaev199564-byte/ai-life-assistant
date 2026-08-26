import XCTest
@testable import AILifeAssistant

/// Матрица деградации: проверяем обе оси, версию системы и железо.
final class CapabilitiesTests: XCTestCase {

    // MARK: Железо

    /// iPhone 15 Pro: первое устройство с кнопкой действия и Apple Intelligence.
    func testIPhone15ProHasActionButtonAndAppleIntelligence() {
        let device = DeviceCapabilities(modelIdentifier: "iPhone16,1")
        XCTAssertTrue(device.hasActionButton)
        XCTAssertTrue(device.supportsAppleIntelligenceHardware)
        XCTAssertTrue(device.hasDynamicIsland)
    }

    /// iPhone 14 Pro: остров есть, кнопки действия нет.
    func testIPhone14ProHasIslandButNoActionButton() {
        let device = DeviceCapabilities(modelIdentifier: "iPhone15,3")
        XCTAssertFalse(device.hasActionButton)
        XCTAssertFalse(device.supportsAppleIntelligenceHardware)
        XCTAssertTrue(device.hasDynamicIsland)
    }

    /// iPhone 14 обычный: ни острова, ни кнопки.
    func testRegularIPhone14HasNeither() {
        let device = DeviceCapabilities(modelIdentifier: "iPhone14,7")
        XCTAssertFalse(device.hasActionButton)
        XCTAssertFalse(device.hasDynamicIsland)
        XCTAssertFalse(device.supportsAppleIntelligenceHardware)
    }

    /// Линейка iPhone 16: кнопка действия у всех моделей.
    func testIPhone16LineHasActionButton() {
        for identifier in ["iPhone17,1", "iPhone17,3", "iPhone17,4"] {
            let device = DeviceCapabilities(modelIdentifier: identifier)
            XCTAssertTrue(device.hasActionButton, "Ожидалась кнопка действия у \(identifier)")
        }
    }

    /// Неизвестный идентификатор не должен обещать возможностей.
    func testUnknownDeviceIsConservative() {
        let device = DeviceCapabilities(modelIdentifier: "iPad14,3")
        XCTAssertFalse(device.hasActionButton)
        XCTAssertFalse(device.supportsAppleIntelligenceHardware)
    }

    // MARK: Версия системы

    /// iOS 18: современного Speech API и локальной модели нет,
    /// Пункт управления доступен.
    func testIOS18DisablesModernAPIs() {
        let capabilities = Capabilities(
            device: DeviceCapabilities(modelIdentifier: "iPhone16,1"),
            osVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 5, patchVersion: 0)
        )
        XCTAssertFalse(capabilities.hasModernSpeechAPI)
        XCTAssertFalse(capabilities.hasFoundationModels)
        XCTAssertTrue(capabilities.hasControlCenterControls)
        XCTAssertEqual(capabilities.onDeviceParsing, .heuristics)
    }

    /// iOS 26 плюс подходящее железо: доступно всё.
    func testIOS26WithCapableHardwareEnablesFoundationModels() {
        let capabilities = Capabilities(
            device: DeviceCapabilities(modelIdentifier: "iPhone16,1"),
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertTrue(capabilities.hasModernSpeechAPI)
        XCTAssertTrue(capabilities.hasFoundationModels)
        XCTAssertEqual(capabilities.onDeviceParsing, .foundationModels)
    }

    /// Ключевой случай: свежая система на старом железе.
    /// Локальной модели нет, хотя версия системы новая.
    func testIOS26OnOlderHardwareFallsBackToHeuristics() {
        let capabilities = Capabilities(
            device: DeviceCapabilities(modelIdentifier: "iPhone14,7"),
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertTrue(capabilities.hasModernSpeechAPI, "Новый Speech API зависит только от версии")
        XCTAssertFalse(capabilities.hasFoundationModels, "Локальная модель требует железа")
        XCTAssertEqual(capabilities.onDeviceParsing, .heuristics)
    }

    // MARK: Точка входа

    func testPrimaryTriggerPrefersActionButton() {
        let capabilities = Capabilities(
            device: DeviceCapabilities(modelIdentifier: "iPhone16,1"),
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(capabilities.primaryTrigger, .actionButton)
    }

    func testPrimaryTriggerFallsBackToControlCenter() {
        let capabilities = Capabilities(
            device: DeviceCapabilities(modelIdentifier: "iPhone14,7"),
            osVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(capabilities.primaryTrigger, .controlCenter)
    }
}
