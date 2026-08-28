import Foundation
import XCTest
@testable import AILifeAssistant

/// Голос за пределами тихой комнаты.
///
/// Детектор не зависит от AVFoundation, поэтому маршруты и уровни сигнала
/// проверяются подачей чисел, без микрофона.
final class VoiceRobustnessTests: XCTestCase {

    /// Пресет под Bluetooth: гарнитура в профиле HFP отдаёт сигнал заметно
    /// тише встроенного микрофона, и с общими порогами запись обрывалась
    /// через четыре секунды с «речь не распознана», хотя человек говорил.
    func testHearsQuietBluetoothSignal() {
        var configuration = VoiceActivityDetector.Configuration.default
        configuration.speechThreshold *= 0.4
        configuration.silenceThreshold *= 0.4

        var detector = VoiceActivityDetector(configuration: configuration)
        var heard = false
        var timestamp: TimeInterval = 0

        // Тихая речь через HFP: около 0.009, ниже обычного порога 0.015.
        for _ in 0..<20 {
            if case .speaking = detector.process(level: 0.009, timestamp: timestamp) {
                heard = true
            }
            timestamp += 0.05
        }

        XCTAssertTrue(heard, "Тихий сигнал гарнитуры должен считаться речью")
    }

    /// Тот же сигнал с обычными порогами не слышен: именно поэтому пресет
    /// и нужен, а не просто «понизить порог всем».
    func testSameSignalIsSilentWithDefaultThresholds() {
        var detector = VoiceActivityDetector(configuration: .default)
        var timestamp: TimeInterval = 0

        for _ in 0..<20 {
            if case .speaking = detector.process(level: 0.009, timestamp: timestamp) {
                return XCTFail("С обычными порогами такой уровень это не речь")
            }
            timestamp += 0.05
        }
    }

    /// Понижение порогов не должно превращать шорох в речь: между уровнем
    /// гарнитуры и уровнем тишины остаётся запас.
    func testQuietPresetStillIgnoresNoise() {
        var configuration = VoiceActivityDetector.Configuration.default
        configuration.speechThreshold *= 0.4
        configuration.silenceThreshold *= 0.4

        var detector = VoiceActivityDetector(configuration: configuration)
        var timestamp: TimeInterval = 0

        for _ in 0..<10 {
            if case .speaking = detector.process(level: 0.002, timestamp: timestamp) {
                return XCTFail("Шорох не должен считаться речью даже с пониженным порогом")
            }
            timestamp += 0.05
        }
    }
}
