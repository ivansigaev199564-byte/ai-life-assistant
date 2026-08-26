import XCTest
@testable import AILifeAssistant

/// Логика автостопа проверяется без микрофона: детектор принимает
/// готовые уровни сигнала, поэтому весь сценарий воспроизводим точно.
final class VoiceActivityDetectorTests: XCTestCase {

    private let speechLevel: Float = 0.08
    private let silenceLevel: Float = 0.002

    /// Пользователь нажал кнопку и молчит: сессия закрывается сама.
    func testStopsWhenUserNeverSpeaks() {
        var detector = VoiceActivityDetector(configuration: .default)
        var lastDecision: VoiceActivityDetector.Decision = .waitingForSpeech

        // Идём с шагом 50 мс до истечения таймаута ожидания первого звука.
        for step in 0...100 {
            let timestamp = Double(step) * 0.05
            lastDecision = detector.process(level: silenceLevel, timestamp: timestamp)
            if case .stop = lastDecision { break }
        }

        XCTAssertEqual(lastDecision, .stop(.noSpeech))
        XCTAssertFalse(detector.hasDetectedSpeech)
    }

    /// Обычный сценарий: фраза, затем пауза, автостоп по тишине.
    func testStopsAfterSilenceFollowingSpeech() {
        var detector = VoiceActivityDetector(configuration: .default)

        // Две секунды речи.
        for step in 0..<40 {
            let decision = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
            XCTAssertEqual(decision, .speaking)
        }
        XCTAssertTrue(detector.hasDetectedSpeech)

        // Тишина до срабатывания автостопа.
        var stopDecision: VoiceActivityDetector.Decision?
        for step in 40..<120 {
            let decision = detector.process(level: silenceLevel, timestamp: Double(step) * 0.05)
            if case .stop = decision {
                stopDecision = decision
                break
            }
        }

        XCTAssertEqual(stopDecision, .stop(.silence))
    }

    /// Пауза короче порога речь не обрывает: человек просто думает.
    func testShortPauseDoesNotStopRecording() {
        var detector = VoiceActivityDetector(configuration: .default)

        for step in 0..<20 {
            _ = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
        }

        // Пауза 0,8 секунды, меньше порога 1,4.
        for step in 20..<36 {
            let decision = detector.process(level: silenceLevel, timestamp: Double(step) * 0.05)
            XCTAssertEqual(decision, .pausing)
        }

        // Речь возобновилась, счётчик тишины сброшен.
        let resumed = detector.process(level: speechLevel, timestamp: 1.85)
        XCTAssertEqual(resumed, .speaking)
    }

    /// Случайный щелчок вместо фразы не должен создавать запись.
    func testTooShortSpeechIsTreatedAsNoSpeech() {
        var detector = VoiceActivityDetector(configuration: .default)

        // Один короткий всплеск: 100 мс, меньше минимальной длительности речи.
        _ = detector.process(level: speechLevel, timestamp: 0.0)
        _ = detector.process(level: speechLevel, timestamp: 0.1)

        var stopDecision: VoiceActivityDetector.Decision?
        for step in 3..<80 {
            let decision = detector.process(level: silenceLevel, timestamp: Double(step) * 0.05)
            if case .stop = decision {
                stopDecision = decision
                break
            }
        }

        XCTAssertEqual(stopDecision, .stop(.noSpeech))
    }

    /// Непрерывная речь обрывается по потолку длительности.
    func testStopsAtMaximumDuration() {
        var configuration = VoiceActivityDetector.Configuration.default
        configuration.maximumDuration = 3

        var detector = VoiceActivityDetector(configuration: configuration)
        var stopDecision: VoiceActivityDetector.Decision?

        for step in 0..<200 {
            let decision = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
            if case .stop = decision {
                stopDecision = decision
                break
            }
        }

        XCTAssertEqual(stopDecision, .stop(.maxDuration))
    }

    /// Уровень между порогами не должен дёргать состояние туда-сюда.
    func testHysteresisZoneKeepsState() {
        var detector = VoiceActivityDetector(configuration: .default)
        let middleLevel: Float = 0.012 // между silenceThreshold и speechThreshold

        for step in 0..<10 {
            _ = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
        }

        let decision = detector.process(level: middleLevel, timestamp: 0.55)
        XCTAssertEqual(decision, .speaking, "В зоне гистерезиса состояние сохраняется")
    }

    /// Режим надиктовки терпит более длинные паузы.
    func testDictationModeToleratesLongerPauses() {
        var detector = VoiceActivityDetector(configuration: .dictation)

        for step in 0..<40 {
            _ = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
        }

        // Пауза 2 секунды: в обычном режиме это остановка, в режиме надиктовки нет.
        var decisions: [VoiceActivityDetector.Decision] = []
        for step in 40..<80 {
            decisions.append(detector.process(level: silenceLevel, timestamp: Double(step) * 0.05))
        }

        XCTAssertFalse(decisions.contains { if case .stop = $0 { return true } else { return false } })
    }

    /// Пиковый уровень нужен для диагностики «микрофон не слышит».
    func testTracksPeakLevel() {
        var detector = VoiceActivityDetector(configuration: .default)
        _ = detector.process(level: 0.03, timestamp: 0)
        _ = detector.process(level: 0.42, timestamp: 0.05)
        _ = detector.process(level: 0.10, timestamp: 0.10)

        XCTAssertEqual(detector.peakLevel, 0.42, accuracy: 0.0001)
    }

    /// После сброса детектор ведёт себя как новый.
    func testResetClearsState() {
        var detector = VoiceActivityDetector(configuration: .default)
        for step in 0..<30 {
            _ = detector.process(level: speechLevel, timestamp: Double(step) * 0.05)
        }
        XCTAssertTrue(detector.hasDetectedSpeech)

        detector.reset()
        XCTAssertFalse(detector.hasDetectedSpeech)
        XCTAssertEqual(detector.peakLevel, 0)
        XCTAssertEqual(detector.accumulatedSpeech, 0)
    }
}
