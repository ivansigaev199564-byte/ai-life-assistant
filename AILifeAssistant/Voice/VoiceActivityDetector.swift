import Foundation

/// Детектор голосовой активности.
///
/// Намеренно не зависит от AVFoundation: принимает уровень сигнала и время,
/// возвращает решение. Благодаря этому логика автостопа полностью
/// покрывается юнит-тестами без микрофона.
struct VoiceActivityDetector {

    struct Configuration: Sendable, Equatable {
        /// Порог линейного RMS, выше которого считаем, что человек говорит.
        /// 0.015 примерно соответствует -36 dBFS: тихая речь проходит,
        /// шум комнаты и вентилятор нет.
        var speechThreshold: Float = 0.015

        /// Гистерезис: порог, ниже которого считаем тишиной. Держим его ниже
        /// порога речи, иначе на границе детектор дребезжит.
        var silenceThreshold: Float = 0.010

        /// Сколько тишины после речи ждать до автостопа.
        var silenceDuration: TimeInterval = 1.4

        /// Короче этого фразу считаем случайным щелчком, а не речью.
        var minimumSpeechDuration: TimeInterval = 0.35

        /// Потолок длительности записи.
        var maximumDuration: TimeInterval = 60

        /// Сколько ждать первого звука, прежде чем закрыть сессию.
        var leadingSilenceTimeout: TimeInterval = 4

        static let `default` = Configuration()

        /// Более терпеливый режим для длинных надиктовок.
        static let dictation = Configuration(
            speechThreshold: 0.015,
            silenceThreshold: 0.010,
            silenceDuration: 2.5,
            minimumSpeechDuration: 0.35,
            maximumDuration: 300,
            leadingSilenceTimeout: 6
        )
    }

    enum Decision: Equatable {
        /// Ждём начала речи.
        case waitingForSpeech
        /// Человек говорит.
        case speaking
        /// Речь была, сейчас пауза, но ещё не пора останавливаться.
        case pausing
        /// Пора останавливать запись.
        case stop(SpeechFinishReason)
    }

    private let configuration: Configuration

    /// Момент запуска, задаётся первым вызовом process.
    private var startTime: TimeInterval?
    /// Когда впервые услышали речь.
    private var speechStartTime: TimeInterval?
    /// Когда началась текущая пауза.
    private var silenceStartTime: TimeInterval?
    /// Суммарная длительность речи, без пауз.
    private(set) var accumulatedSpeech: TimeInterval = 0
    private var lastTimestamp: TimeInterval?
    private var isFinished = false

    /// Пиковый уровень за сессию, полезен для диагностики «не слышно микрофон».
    private(set) var peakLevel: Float = 0

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    var hasDetectedSpeech: Bool { speechStartTime != nil }

    /// Обрабатывает очередной замер уровня.
    /// - Parameters:
    ///   - level: линейный RMS уровня сигнала, 0...1.
    ///   - timestamp: монотонное время в секундах.
    mutating func process(level: Float, timestamp: TimeInterval) -> Decision {
        guard !isFinished else { return .stop(.manual) }

        if startTime == nil { startTime = timestamp }
        let start = startTime ?? timestamp
        peakLevel = max(peakLevel, level)

        // Накапливаем длительность речи по дельте между замерами.
        if let last = lastTimestamp, level >= configuration.speechThreshold {
            accumulatedSpeech += max(0, timestamp - last)
        }
        lastTimestamp = timestamp

        let elapsed = timestamp - start
        if elapsed >= configuration.maximumDuration {
            isFinished = true
            return .stop(.maxDuration)
        }

        let isSpeech = level >= configuration.speechThreshold
        let isSilence = level < configuration.silenceThreshold

        if isSpeech {
            if speechStartTime == nil { speechStartTime = timestamp }
            silenceStartTime = nil
            return .speaking
        }

        guard speechStartTime != nil else {
            // Человек ещё не начинал говорить.
            if elapsed >= configuration.leadingSilenceTimeout {
                isFinished = true
                return .stop(.noSpeech)
            }
            return .waitingForSpeech
        }

        guard isSilence else {
            // Уровень в зоне гистерезиса: не речь, но и не тишина.
            // Ничего не меняем, ждём определённости.
            return silenceStartTime == nil ? .speaking : .pausing
        }

        if silenceStartTime == nil { silenceStartTime = timestamp }
        let silenceElapsed = timestamp - (silenceStartTime ?? timestamp)

        if silenceElapsed >= configuration.silenceDuration {
            isFinished = true
            // Слишком короткая фраза это, скорее всего, случайное нажатие.
            let reason: SpeechFinishReason = accumulatedSpeech >= configuration.minimumSpeechDuration
                ? .silence
                : .noSpeech
            return .stop(reason)
        }

        return .pausing
    }

    /// Сброс состояния для повторного использования детектора.
    mutating func reset() {
        startTime = nil
        speechStartTime = nil
        silenceStartTime = nil
        lastTimestamp = nil
        accumulatedSpeech = 0
        peakLevel = 0
        isFinished = false
    }
}
