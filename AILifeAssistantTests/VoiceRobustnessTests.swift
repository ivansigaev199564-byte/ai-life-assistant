import Foundation
import XCTest
@testable import AILifeAssistant

/// Голос в реальных условиях: улица, машина, гарнитура, метро.
/// Детектор не зависит от AVFoundation, поэтому всё это проверяется
/// без микрофона, подачей уровней сигнала.
final class VoiceRobustnessTests: XCTestCase {

    /// Уличный шум перекрывал абсолютный порог речи, детектор считал его
    /// голосом, и запись не останавливалась никогда.
    func testStopsInNoisyPlace() {
        var detector = VoiceActivityDetector(configuration: .default)
        var timestamp: TimeInterval = 0
        let noise: Float = 0.02

        // Фон измеряется в первые доли секунды.
        for _ in 0..<10 {
            _ = detector.process(level: noise, timestamp: timestamp)
            timestamp += 0.04
        }

        // Речь заметно громче фона.
        for _ in 0..<40 {
            _ = detector.process(level: noise * 5, timestamp: timestamp)
            timestamp += 0.04
        }

        // Человек замолчал: остался прежний фон.
        var decision: VoiceActivityDetector.Decision = .speaking
        for _ in 0..<60 {
            decision = detector.process(level: noise, timestamp: timestamp)
            timestamp += 0.04
            if case .stop = decision { break }
        }

        guard case .stop(let reason) = decision else {
            return XCTFail("Автостоп не сработал в шумном месте, получено \(decision)")
        }
        XCTAssertEqual(reason, .silence)
    }

    /// Гарнитура отдаёт сигнал заметно тише встроенного микрофона, и запись
    /// обрывалась через четыре секунды с «речь не распознана».
    func testHearsQuietBluetoothSignal() {
        var configuration = VoiceActivityDetector.Configuration.default
        configuration.speechThreshold *= 0.4
        configuration.silenceThreshold *= 0.4

        var detector = VoiceActivityDetector(configuration: configuration)
        var timestamp: TimeInterval = 0

        for _ in 0..<8 {
            _ = detector.process(level: 0.001, timestamp: timestamp)
            timestamp += 0.04
        }

        // Тихая речь через HFP: около 0.009, ниже прежнего порога 0.015.
        var heard = false
        for _ in 0..<30 {
            if case .speaking = detector.process(level: 0.009, timestamp: timestamp) {
                heard = true
            }
            timestamp += 0.04
        }

        XCTAssertTrue(heard, "Тихий сигнал гарнитуры должен считаться речью")
    }

    /// В тихой комнате пороги остаются прежними: адаптация не должна
    /// принимать за речь шелест страниц.
    func testKeepsThresholdsInQuietRoom() {
        var detector = VoiceActivityDetector(configuration: .default)
        var timestamp: TimeInterval = 0

        for _ in 0..<10 {
            _ = detector.process(level: 0.0005, timestamp: timestamp)
            timestamp += 0.04
        }

        let decision = detector.process(level: 0.004, timestamp: timestamp)
        if case .speaking = decision {
            XCTFail("Тихий шорох не должен считаться речью в тишине")
        }
    }

    /// Одиночный хлопок дверью в момент замера фона не должен поднимать
    /// порог на всю сессию: поэтому берётся медиана, а не среднее.
    func testSinglePeakDoesNotRaiseFloor() {
        var detector = VoiceActivityDetector(configuration: .default)
        var timestamp: TimeInterval = 0

        let samples: [Float] = [0.001, 0.001, 0.5, 0.001, 0.001, 0.001]
        for sample in samples {
            _ = detector.process(level: sample, timestamp: timestamp)
            timestamp += 0.05
        }

        var heard = false
        for _ in 0..<20 {
            if case .speaking = detector.process(level: 0.02, timestamp: timestamp) {
                heard = true
            }
            timestamp += 0.04
        }

        XCTAssertTrue(heard, "После одиночного пика обычная речь должна слышаться")
    }
}
