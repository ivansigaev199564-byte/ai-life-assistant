import AVFoundation
import Foundation
import Speech

/// Распознавание через SFSpeechRecognizer.
///
/// Базовый движок для всего поддерживаемого диапазона iOS. Даёт текст по ходу
/// речи, что и создаёт ощущение мгновенной реакции. Требует явной локали:
/// автоопределение языка этот API не умеет.
@MainActor
final class AppleSpeechRecognizer: NSObject, SpeechRecognizing {

    let kind: SpeechEngineKind = .appleSpeech
    let supportsPartialResults = true
    let supportsAutomaticLanguageDetection = false

    private var recognizer: SFSpeechRecognizer?
    /// Запрос живёт в потокобезопасной обёртке: буферы приходят с аудиопотока,
    /// а свойства этого класса изолированы главным актором.
    private let requestBox = RecognitionRequestBox()
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?

    /// Последний непустой текст. Нужен, если система закрыла задачу без
    /// финального результата: лучше отдать накопленное, чем ничего.
    private var lastTranscript: String = ""
    private var lastConfidence: Double = 0
    private var activeLocale: Locale = .current
    private var didEmitFinal = false

    // MARK: Подготовка

    func prepare() async throws {
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            throw AppError.speechPermissionDenied
        }
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Поддерживается ли язык на устройстве.
    static func supports(locale: Locale) -> Bool {
        SFSpeechRecognizer.supportedLocales().contains { $0.identifier == locale.identifier }
    }

    // MARK: Сессия

    func beginSession(locale: Locale) async throws -> AsyncStream<TranscriptionEvent> {
        try await prepare()

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppError.speechRecognizerUnavailable(locale: locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw AppError.speechRecognizerUnavailable(locale: locale.identifier)
        }

        self.recognizer = recognizer
        self.activeLocale = locale
        self.lastTranscript = ""
        self.lastConfidence = 0
        self.didEmitFinal = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Локальное распознавание работает без сети и не отправляет звук наружу.
        // Если язык не установлен на устройстве, откатываемся на серверное.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        requestBox.set(request)

        let stream = AsyncStream<TranscriptionEvent> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.teardown()
                }
            }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Колбэк приходит на внутренней очереди Speech, поэтому возвращаемся на главный актор.
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error)
            }
        }

        Log.voice.debug("""
            Apple Speech: сессия открыта, локаль \(locale.identifier, privacy: .public), \
            на устройстве: \(recognizer.supportsOnDeviceRecognition)
            """)

        return stream
    }

    nonisolated func append(buffer: AVAudioPCMBuffer) {
        // Вызывается с аудиопотока, поэтому идём через обёртку с блокировкой,
        // а не через свойство главного актора.
        requestBox.append(buffer)
    }

    func finishSession(audioFileURL: URL?) async {
        // Сообщаем, что звук закончился, и ждём финальный результат ограниченное время.
        requestBox.endAudio()

        let deadline = Date().addingTimeInterval(2.0)
        while !didEmitFinal, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !didEmitFinal {
            // Система не прислала финал: отдаём накопленный текст, чтобы
            // пользователь не потерял сказанное.
            emitFinal(text: lastTranscript, confidence: lastConfidence)
        }
        teardown()
    }

    func cancelSession() async {
        task?.cancel()
        continuation?.finish()
        teardown()
    }

    // MARK: Обработка результата

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                lastTranscript = text
                lastConfidence = Self.averageConfidence(of: result.bestTranscription)
            }

            if result.isFinal {
                emitFinal(text: text, confidence: lastConfidence)
                return
            }
            continuation?.yield(.partial(text))
            return
        }

        guard let error else { return }
        let nsError = error as NSError

        // Код 216 приходит при штатной отмене задачи, код 1110 когда речи не было.
        // Это не ошибки сценария, поэтому финализируем тем, что есть.
        let benignCodes = [216, 1110, 301]
        if benignCodes.contains(nsError.code) {
            emitFinal(text: lastTranscript, confidence: lastConfidence)
            return
        }

        Log.voice.error("Apple Speech: ошибка \(nsError.code) \(nsError.localizedDescription)")
        continuation?.yield(.failed(.recognitionFailed(underlying: nsError.localizedDescription)))
        continuation?.finish()
        didEmitFinal = true
    }

    private func emitFinal(text: String, confidence: Double) {
        guard !didEmitFinal else { return }
        didEmitFinal = true
        continuation?.yield(
            .final(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: confidence,
                languageCode: activeLocale.identifier
            )
        )
        continuation?.finish()
    }

    /// Средняя уверенность по сегментам. Промежуточные сегменты приходят
    /// с нулевой уверенностью, поэтому считаем только по заполненным.
    private static func averageConfidence(of transcription: SFTranscription) -> Double {
        let scored = transcription.segments.filter { $0.confidence > 0 }
        guard !scored.isEmpty else { return 0 }
        let sum = scored.reduce(into: Double(0)) { $0 += Double($1.confidence) }
        return sum / Double(scored.count)
    }

    private func teardown() {
        task = nil
        requestBox.set(nil)
        recognizer = nil
        continuation = nil
    }
}


/// Потокобезопасный держатель запроса распознавания.
///
/// `SFSpeechAudioBufferRecognitionRequest` допускает добавление буферов
/// с любого потока, но ссылку на него нужно читать под блокировкой:
/// сессия закрывается на главном акторе, а буферы идут с аудиопотока.
private final class RecognitionRequestBox: @unchecked Sendable {

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func endAudio() {
        lock.lock()
        let current = request
        lock.unlock()
        current?.endAudio()
    }
}
