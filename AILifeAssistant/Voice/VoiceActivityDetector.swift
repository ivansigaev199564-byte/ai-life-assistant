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

        /// Сколько времени в начале сессии слушать фон, чтобы понять,
        /// насколько вокруг шумно.
        var noiseWindow: TimeInterval = 0.3

        /// Во сколько раз речь должна быть громче измеренного фона.
        ///
        /// Пороги были заданы абсолютными числами, и это ломало запись
        /// в обе стороны: на улице шум перекрывал порог речи и автостоп
        /// не срабатывал никогда, а тихий сигнал Bluetooth-гарнитуры
        /// до порога не дотягивал, и запись обрывалась через четыре
        /// секунды с «речь не распознана».
        var speechOverNoise: Float = 3.0

        /// Во сколько раз тишина должна быть громче фона.
        var silenceOverNoise: Float = 1.6

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

    /// Замеры фона в первые доли секунды сессии.
    private var noiseSamples: [Float] = []
    /// Измеренный шумовой пол. Пока не измерен, работают пороги из настроек.
    private var noiseFloor: Float?
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

        // Первые доли секунды слушаем фон: пороги должны считаться от него,
        // а не от абсолютного числа, одинакового для тихой комнаты,
        // шумной улицы и гарнитуры.
        if speechStartTime == nil, elapsed <= configuration.noiseWindow {
            noiseSamples.append(level)
        } else if noiseFloor == nil, !noiseSamples.isEmpty {
            noiseFloor = Self.median(of: noiseSamples)
            noiseSamples = []
        }

        let isSpeech = level >= speechThreshold
        let isSilence = level < silenceThreshold

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

    /// Порог речи: не ниже настроенного и заметно выше измеренного фона.
    private var speechThreshold: Float {
        guard let noiseFloor else { return configuration.speechThreshold }
        return max(configuration.speechThreshold * 0.4, noiseFloor * configuration.speechOverNoise)
    }

    /// Порог тишины держится ниже порога речи: иначе детектор дребезжит
    /// на границе.
    private var silenceThreshold: Float {
        guard let noiseFloor else { return configuration.silenceThreshold }
        return min(
            speechThreshold * 0.7,
            max(configuration.silenceThreshold * 0.4, noiseFloor * configuration.silenceOverNoise)
        )
    }

    /// Медиана устойчивее среднего: одиночный хлопок дверью не должен
    /// поднимать порог на всю сессию.
    private static func median(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
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
        noiseSamples = []
        noiseFloor = nil
    }
}
