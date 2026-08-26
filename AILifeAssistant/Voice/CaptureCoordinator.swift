import AVFoundation
import Foundation
import Observation
import SwiftData

/// Оркестратор голосового захвата: разрешения, аудиосессия, движок
/// распознавания, детектор тишины и запись результата в базу.
///
/// Единственный объект, который UI и App Intents дёргают для записи.
/// Порядок операций подчинён требованию отклика: тактильный сигнал уходит
/// первым, всё остальное после.
@MainActor
@Observable
final class CaptureCoordinator {

    enum Phase: Equatable {
        case idle
        /// Проверяем разрешения и поднимаем аудиосессию.
        case preparing
        /// Идёт запись.
        case listening
        /// Запись остановлена, ждём финальный текст.
        case finalizing
        case failed(AppError)

        var isActive: Bool {
            self == .preparing || self == .listening || self == .finalizing
        }
    }

    // MARK: Наблюдаемое состояние

    private(set) var phase: Phase = .idle
    /// Сглаженный уровень сигнала 0...1 для визуализации.
    private(set) var audioLevel: Float = 0
    /// Текст по ходу речи. Пуст у движков без потокового режима.
    private(set) var liveTranscript: String = ""
    /// Сколько идёт текущая запись.
    private(set) var elapsed: TimeInterval = 0
    /// Последний сохранённый захват, нужен для баннера отмены на Этапе 5.
    private(set) var lastSavedCapture: CaptureItem?
    /// Слышал ли детектор речь: по этому флагу UI подсказывает «говорите громче».
    private(set) var hasDetectedSpeech = false

    // MARK: Зависимости

    private let modelContext: ModelContext
    private let permissions: PermissionsManager
    private let settings: AppSettings
    private let sessionManager: AudioSessionManager
    private let recordingStore: RecordingStore
    private let haptics: HapticEngine

    /// Вызывается после сохранения захвата. На Этапе 2 сюда подключится
    /// конвейер разбора, сейчас используется для обновления интерфейса.
    var onCaptureSaved: ((CaptureItem) -> Void)?

    // MARK: Внутреннее состояние сессии

    private var recorder: AudioEngineRecorder?
    private var engine: SpeechRecognizing?
    private var detector: VoiceActivityDetector
    private var eventsTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    private var captureID = UUID()
    private var captureSource: CaptureSource = .inApp
    private var recordingURL: URL?
    private var startedAt: TimeInterval?
    private var finishReason: SpeechFinishReason = .manual
    private var isStopping = false

    /// Итоговый текст, пришедший из движка.
    private var finalText: String?
    private var finalConfidence: Double = 0
    private var finalLanguage: String?

    init(
        modelContext: ModelContext,
        permissions: PermissionsManager,
        settings: AppSettings,
        // Значения по умолчанию вычисляются вне изоляции актора, поэтому
        // изолированные объекты создаём внутри инициализатора, а не в сигнатуре.
        sessionManager: AudioSessionManager? = nil,
        recordingStore: RecordingStore = RecordingStore(),
        haptics: HapticEngine? = nil
    ) {
        self.modelContext = modelContext
        self.permissions = permissions
        self.settings = settings
        self.sessionManager = sessionManager ?? AudioSessionManager()
        self.recordingStore = recordingStore
        self.haptics = haptics ?? .shared
        self.detector = VoiceActivityDetector(configuration: settings.vadConfiguration)

        self.sessionManager.onInterruption = { [weak self] interruption in
            guard let self else { return }
            switch interruption {
            case .began, .mediaServicesReset, .routeChanged:
                Task { await self.stop(reason: .interrupted) }
            case .ended:
                // Автовозобновление не делаем: пользователь сам решит,
                // повторять ли фразу после звонка.
                break
            }
        }
    }

    // MARK: Публичные операции

    /// Запускает захват. Тактильный отклик уходит синхронно, до любых ожиданий.
    func start(source: CaptureSource) async {
        guard !phase.isActive else {
            Log.voice.debug("Запрос захвата проигнорирован: сессия уже идёт")
            return
        }

        if settings.hapticsEnabled {
            haptics.captureStarted()
        }

        captureSource = source
        captureID = UUID()
        phase = .preparing
        liveTranscript = ""
        audioLevel = 0
        elapsed = 0
        hasDetectedSpeech = false
        finalText = nil
        finalConfidence = 0
        finalLanguage = nil
        finishReason = .manual
        isStopping = false
        detector = VoiceActivityDetector(configuration: settings.vadConfiguration)

        permissions.refresh()
        if !permissions.isReadyForCapture {
            let granted = await permissions.requestAll()
            guard granted else {
                fail(with: permissions.blockingError ?? .microphonePermissionDenied)
                return
            }
        }

        do {
            try await beginSession()
        } catch let error as AppError {
            fail(with: error)
        } catch {
            fail(with: .audioEngineFailed(underlying: error.localizedDescription))
        }
    }

    /// Останавливает запись и сохраняет результат.
    func stop(reason: SpeechFinishReason = .manual) async {
        guard phase == .listening || phase == .preparing else { return }
        guard !isStopping else { return }
        isStopping = true
        finishReason = reason
        phase = .finalizing

        if settings.hapticsEnabled, reason == .manual {
            haptics.captureStopped()
        }

        tickerTask?.cancel()
        tickerTask = nil

        let recording = recorder?.stop()
        recorder = nil
        sessionManager.deactivate()

        // Файловым движкам запись передаётся здесь, потоковые просто закрывают поток.
        await engine?.finishSession(audioFileURL: recording?.fileURL)

        // Ждём, пока обработчик событий примет финальный текст и завершится.
        await eventsTask?.value
        eventsTask = nil

        let didSave = await persistResult(duration: recording?.duration ?? elapsed)

        engine = nil
        isStopping = false

        // Фазу сбрасываем только при успехе: иначе затрём сообщение об ошибке,
        // которое пользователь ещё не увидел.
        if didSave {
            phase = .idle
        }
    }

    /// Прерывает запись без сохранения и удаляет аудиофайл.
    func cancel() async {
        guard phase.isActive else { return }
        isStopping = true

        tickerTask?.cancel()
        tickerTask = nil
        eventsTask?.cancel()
        eventsTask = nil

        recorder?.stop()
        recorder?.discardRecording()
        recorder = nil

        await engine?.cancelSession()
        engine = nil

        sessionManager.deactivate()

        liveTranscript = ""
        audioLevel = 0
        elapsed = 0
        isStopping = false
        phase = .idle
    }

    /// Сохраняет захват, набранный текстом. Используется Share Extension
    /// и ручным вводом в интерфейсе.
    @discardableResult
    func saveTextCapture(_ text: String, source: CaptureSource = .manualText) -> CaptureItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let capture = CaptureItem(
            text: trimmed,
            status: .pending,
            source: source,
            engine: .none,
            recognitionConfidence: 1
        )
        modelContext.insert(capture)
        save(context: "текстовый захват")
        lastSavedCapture = capture
        onCaptureSaved?(capture)
        return capture
    }
}

// MARK: - Внутренняя механика

private extension CaptureCoordinator {

    /// Поднимает аудиосессию, движок распознавания и рекордер.
    func beginSession() async throws {
        let engine = SpeechEngineFactory.make(preference: settings.enginePreference)
        self.engine = engine

        // Модель WhisperKit должна быть загружена до старта записи,
        // иначе первые секунды речи уйдут в пустоту.
        try await engine.prepare()

        try sessionManager.activateForRecording()

        let stream = try await engine.beginSession(locale: settings.resolvedLocale)
        observe(stream: stream)

        // Файл нужен файловым движкам всегда, остальным только если
        // пользователь захотел хранить аудио.
        let needsFile = engine.requiresAudioFile || settings.keepAudioRecordings
        if needsFile {
            recordingURL = try? recordingStore.makeRecordingURL(for: captureID)
        } else {
            recordingURL = nil
        }

        let recorder = AudioEngineRecorder()
        recorder.onBuffer = { [weak engine] buffer, _ in
            engine?.append(buffer: buffer)
        }
        recorder.onLevel = { [weak self] level, timestamp in
            Task { @MainActor [weak self] in
                self?.handleLevel(level, timestamp: timestamp)
            }
        }

        do {
            try recorder.start(recordingURL: recordingURL)
        } catch {
            sessionManager.deactivate()
            await engine.cancelSession()
            throw error
        }

        self.recorder = recorder
        startedAt = ProcessInfo.processInfo.systemUptime
        phase = .listening
        startTicker()

        Log.voice.notice("""
            Захват начат: источник \(self.captureSource.rawValue, privacy: .public), \
            движок \(engine.kind.rawValue, privacy: .public)
            """)
    }

    /// Подписка на текстовые события движка.
    func observe(stream: AsyncStream<TranscriptionEvent>) {
        eventsTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .partial(let text):
                    self.liveTranscript = text

                case .final(let text, let confidence, let language):
                    self.finalText = text
                    self.finalConfidence = confidence
                    self.finalLanguage = language
                    if !text.isEmpty { self.liveTranscript = text }

                case .failed(let error):
                    Log.voice.error("Движок распознавания вернул ошибку: \(error.localizedDescription)")
                    // Ошибку не показываем сразу: возможно, текст уже накоплен
                    // и его стоит сохранить. Решение принимается при финализации.
                    if self.finalText == nil {
                        self.finalText = self.liveTranscript
                        self.finalConfidence = 0
                    }
                }
            }
        }
    }

    /// Уровень сигнала: сглаживание для интерфейса и решение детектора тишины.
    func handleLevel(_ level: Float, timestamp: TimeInterval) {
        guard phase == .listening else { return }

        // Экспоненциальное сглаживание: сырой RMS дёргается слишком резко,
        // индикатор с ним выглядит нервным.
        audioLevel = audioLevel * 0.7 + min(1, level * 12) * 0.3

        let decision = detector.process(level: level, timestamp: timestamp)
        switch decision {
        case .speaking:
            hasDetectedSpeech = true
        case .waitingForSpeech, .pausing:
            break
        case .stop(let reason):
            Task { await self.stop(reason: reason) }
        }
    }

    /// Тикер длительности для интерфейса.
    func startTicker() {
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            }
        }
    }

    /// Сохраняет результат сессии в базу.
    /// - Returns: удалось ли сохранить захват.
    @discardableResult
    func persistResult(duration: TimeInterval) async -> Bool {
        let text = (finalText ?? liveTranscript).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            // Пустая запись не имеет ценности: чистим файл и сообщаем причину.
            recorder?.discardRecording()
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            recordingURL = nil

            Log.voice.notice("Захват пуст: речь не распознана")
            phase = .failed(.emptyTranscription)
            if settings.hapticsEnabled { haptics.captureFailed() }
            return false
        }

        // Аудио оставляем, только если пользователь этого хотел.
        var storedFileName: String?
        if let recordingURL {
            if settings.keepAudioRecordings {
                storedFileName = recordingURL.lastPathComponent
            } else {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }

        let capture = CaptureItem(
            id: captureID,
            text: text,
            isPartial: false,
            status: .pending,
            source: captureSource,
            engine: engine?.kind ?? .none,
            languageCode: finalLanguage,
            recognitionConfidence: finalConfidence,
            audioDuration: duration,
            audioFileName: storedFileName
        )

        modelContext.insert(capture)
        save(context: "голосовой захват")

        lastSavedCapture = capture
        liveTranscript = text
        recordingURL = nil

        if settings.hapticsEnabled { haptics.captureSaved() }
        Log.voice.notice("""
            Захват сохранён: \(text.count) симв., уверенность \
            \(self.finalConfidence, format: .fixed(precision: 2)), причина \
            \(self.finishReason.rawValue, privacy: .public)
            """)

        onCaptureSaved?(capture)
        return true
    }

    func save(context: String) {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Не удалось сохранить \(context, privacy: .public): \(error.localizedDescription)")
            phase = .failed(.persistenceFailed(underlying: error.localizedDescription))
        }
    }

    func fail(with error: AppError) {
        Log.voice.error("Захват прерван: \(error.localizedDescription)")
        phase = .failed(error)
        if settings.hapticsEnabled { haptics.captureFailed() }

        recorder?.stop()
        recorder?.discardRecording()
        recorder = nil
        sessionManager.deactivate()

        Task { [engine] in
            await engine?.cancelSession()
        }
        engine = nil
    }
}
