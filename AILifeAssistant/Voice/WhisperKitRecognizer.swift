import AVFoundation
import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Распознавание через WhisperKit: локальная модель Whisper на Core ML.
///
/// Работает по готовому файлу, а не по потоку, поэтому текста по ходу речи
/// не даёт. В обмен сам определяет язык, что важно для смешанных фраз вроде
/// «купил кофе за five dollars».
///
/// Модель весит сотни мегабайт и скачивается при первом включении, поэтому
/// движок никогда не выбирается по умолчанию.
@MainActor
final class WhisperKitRecognizer: SpeechRecognizing {

    let kind: SpeechEngineKind = .whisperKit
    let supportsPartialResults = false
    let supportsAutomaticLanguageDetection = true
    let requiresAudioFile = true

    /// Имя модели из каталога argmaxinc. "base" разумный компромисс между
    /// качеством и размером для телефона.
    private let modelName: String

    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var sessionLocale: Locale = .current
    private var isCancelled = false

    #if canImport(WhisperKit)
    private static var sharedPipeline: WhisperKit?
    /// Задача не возвращает саму модель: тип WhisperKit не Sendable,
    /// поэтому результат кладётся в sharedPipeline на главном акторе.
    private static var loadTask: Task<Void, Error>?
    #endif

    init(modelName: String = "base") {
        self.modelName = modelName
    }

    /// Скачана ли модель. UI показывает по этому флагу состояние в настройках.
    static var isModelReady: Bool {
        #if canImport(WhisperKit)
        return sharedPipeline != nil
        #else
        return false
        #endif
    }

    // MARK: Подготовка

    func prepare() async throws {
        #if canImport(WhisperKit)
        _ = try await Self.pipeline(modelName: modelName)
        #else
        throw AppError.whisperModelUnavailable
        #endif
    }

    #if canImport(WhisperKit)
    /// Модель загружается один раз на всё приложение: инициализация занимает
    /// секунды, повторять её на каждую фразу недопустимо.
    private static func pipeline(modelName: String) async throws -> WhisperKit {
        if let sharedPipeline { return sharedPipeline }

        // Загрузка уже идёт: дожидаемся её и берём готовую модель.
        if let loadTask {
            try await loadTask.value
            guard let sharedPipeline else { throw AppError.whisperModelUnavailable }
            return sharedPipeline
        }

        let task = Task<Void, Error> { @MainActor in
            do {
                let config = WhisperKitConfig(model: modelName, download: true)
                WhisperKitRecognizer.sharedPipeline = try await WhisperKit(config)
                Log.voice.notice("WhisperKit: модель \(modelName, privacy: .public) загружена")
            } catch {
                Log.voice.error("WhisperKit: загрузка модели не удалась: \(error.localizedDescription)")
                throw AppError.whisperModelUnavailable
            }
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
            guard let sharedPipeline else { throw AppError.whisperModelUnavailable }
            return sharedPipeline
        } catch {
            // Сбрасываем задачу, чтобы следующая попытка началась заново.
            loadTask = nil
            throw error
        }
    }
    #endif

    // MARK: Сессия

    func beginSession(locale: Locale) async throws -> AsyncStream<TranscriptionEvent> {
        #if canImport(WhisperKit)
        sessionLocale = locale
        isCancelled = false

        // Модель должна быть готова до начала записи, иначе пользователь
        // договорит раньше, чем движок проснётся.
        _ = try await Self.pipeline(modelName: modelName)

        return AsyncStream<TranscriptionEvent> { continuation in
            self.continuation = continuation
        }
        #else
        throw AppError.whisperModelUnavailable
        #endif
    }

    nonisolated func append(buffer: AVAudioPCMBuffer) {
        // Файловый движок буферы не использует: звук пишет рекордер.
    }

    func finishSession(audioFileURL: URL?) async {
        #if canImport(WhisperKit)
        guard !isCancelled else { return }

        guard let audioFileURL, FileManager.default.fileExists(atPath: audioFileURL.path) else {
            continuation?.yield(.failed(.emptyTranscription))
            continuation?.finish()
            continuation = nil
            return
        }

        do {
            let pipeline = try await Self.pipeline(modelName: modelName)

            var options = DecodingOptions()
            // Язык не задаём: пусть модель определяет сама, это её преимущество.
            options.language = nil
            options.detectLanguage = true
            options.temperature = 0
            options.withoutTimestamps = true

            let results = await pipeline.transcribe(
                audioPaths: [audioFileURL.path],
                decodeOptions: options
            )

            guard let transcriptions = results.first ?? nil, !transcriptions.isEmpty else {
                continuation?.yield(.failed(.emptyTranscription))
                continuation?.finish()
                continuation = nil
                return
            }

            let text = transcriptions
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let detectedLanguage = transcriptions.first?.language
            let confidence = Self.confidence(from: transcriptions)

            if text.isEmpty {
                continuation?.yield(.failed(.emptyTranscription))
            } else {
                continuation?.yield(
                    .final(
                        text: text,
                        confidence: confidence,
                        languageCode: detectedLanguage ?? sessionLocale.identifier
                    )
                )
            }
        } catch {
            Log.voice.error("WhisperKit: распознавание не удалось: \(error.localizedDescription)")
            continuation?.yield(.failed(.recognitionFailed(underlying: error.localizedDescription)))
        }

        continuation?.finish()
        continuation = nil
        #else
        continuation?.yield(.failed(.whisperModelUnavailable))
        continuation?.finish()
        continuation = nil
        #endif
    }

    func cancelSession() async {
        isCancelled = true
        continuation?.finish()
        continuation = nil
    }

    #if canImport(WhisperKit)
    /// Whisper не отдаёт готовую уверенность. Переводим средний логарифм
    /// вероятности токенов в шкалу 0...1 и штрафуем сегменты, которые модель
    /// сама пометила как «вероятно тишина».
    private static func confidence(from results: [TranscriptionResult]) -> Double {
        let segments = results.flatMap { $0.segments }
        guard !segments.isEmpty else { return 0 }

        let averageLogProb = segments.reduce(into: Double(0)) { $0 += Double($1.avgLogprob) }
            / Double(segments.count)
        let averageNoSpeech = segments.reduce(into: Double(0)) { $0 += Double($1.noSpeechProb) }
            / Double(segments.count)

        let base = min(1, max(0, exp(averageLogProb)))
        return min(1, max(0, base * (1 - averageNoSpeech)))
    }
    #endif
}
