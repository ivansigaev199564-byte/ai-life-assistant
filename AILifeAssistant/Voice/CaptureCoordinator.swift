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
    /// Последняя сохранённая запись.
    ///
    /// Именно идентификатор, а не объект: разбор и интерфейс живут дольше
    /// одной сессии, а объект SwiftData, переживший свой контекст, роняет
    /// приложение при первом же обращении.
    private(set) var lastSavedCaptureID: UUID?
    /// Слышал ли детектор речь: по этому флагу UI подсказывает «говорите громче».
    private(set) var hasDetectedSpeech = false

    // MARK: Зависимости

    private let modelContext: ModelContext
    private let permissions: PermissionsManager
    private let settings: AppSettings
    private let sessionManager: AudioSessionManager
    private let recordingStore: RecordingStore
    private let haptics: HapticEngine
    /// Динамический остров. Отсутствует в тестах и на устройствах без него.
    private let liveActivity: LiveActivityController?

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
    private var isFinishing = false

    /// Номер текущей сессии.
    ///
    /// Запуск асинхронный и подолгу висит на разрешениях и загрузке модели.
    /// Без этого номера остановка сносила ещё не созданную сессию, а старт
    /// потом спокойно доезжал до конца и включал микрофон уже после того,
    /// как человек всё отменил: индикатор записи горел, а на экране не было
    /// ничего.
    private var sessionGeneration = 0

    /// Итоговый текст, пришедший из движка.
    private var finalText: String?
    private var finalConfidence: Double = 0
    private var finalLanguage: String?

    /// Когда последний раз обновлялся Динамический остров.
    private var lastActivityUpdate: TimeInterval = 0

    init(
        modelContext: ModelContext,
        permissions: PermissionsManager,
        settings: AppSettings,
        // Значения по умолчанию вычисляются вне изоляции актора, поэтому
        // изолированные объекты создаём внутри инициализатора, а не в сигнатуре.
        sessionManager: AudioSessionManager? = nil,
        recordingStore: RecordingStore = RecordingStore(),
        haptics: HapticEngine? = nil,
        liveActivity: LiveActivityController? = nil
    ) {
        self.modelContext = modelContext
        self.permissions = permissions
        self.settings = settings
        self.sessionManager = sessionManager ?? AudioSessionManager()
        self.recordingStore = recordingStore
        self.haptics = haptics ?? .shared
        self.liveActivity = liveActivity
        self.detector = VoiceActivityDetector(configuration: settings.vadConfiguration)

        self.sessionManager.onInterruption = { [weak self] interruption in
            guard let self else { return }
            switch interruption {
            case .routeChanged:
                // Смена маршрута это не обязательно конец записи: чаще
                // всего человек просто надел наушники. Пробуем продолжить
                // на новом устройстве и останавливаемся, только если
                // продолжить не вышло.
                guard self.phase == .listening else { return }

                if self.recorder?.restartForRouteChange() == true {
                    self.applyRoutePreset()
                } else {
                    Task { await self.stop(reason: .interrupted) }
                }

            case .began, .mediaServicesReset:
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
        isFinishing = false
        detector = VoiceActivityDetector(configuration: settings.vadConfiguration)

        sessionGeneration += 1
        let generation = sessionGeneration

        permissions.refresh()
        if !permissions.isReadyForCapture {
            let granted = await permissions.requestAll()
            guard generation == sessionGeneration else { return }
            guard granted else {
                fail(with: permissions.blockingError ?? .microphonePermissionDenied)
                return
            }
        }

        do {
            try await beginSession(generation: generation)
        } catch let error as AppError {
            guard generation == sessionGeneration else { return }
            fail(with: error)
        } catch {
            guard generation == sessionGeneration else { return }
            fail(with: .audioEngineFailed(underlying: error.localizedDescription))
        }
    }

    /// Останавливает запись и сохраняет результат.
    func stop(reason: SpeechFinishReason = .manual) async {
        await finish(saving: true, reason: reason)
    }

    /// Прерывает запись без сохранения и удаляет аудиофайл.
    func cancel() async {
        await finish(saving: false, reason: .manual)
    }

    /// Единственный путь завершения сессии.
    ///
    /// Раньше остановка и отмена жили порознь, и отмена не проверяла флаг
    /// остановки. Нажатие «Отменить» в момент финализации успевало снести
    /// движок и рекордер, после чего остановка всё равно доходила
    /// до сохранения: отменённая запись могла оказаться в ленте.
    private func finish(saving: Bool, reason: SpeechFinishReason) async {
        guard phase.isActive else { return }
        guard !isFinishing else { return }

        isFinishing = true
        finishReason = reason

        // Всё, что ещё летит в запуске, с этого момента устарело.
        sessionGeneration += 1

        if saving {
            phase = .finalizing
            if settings.hapticsEnabled, reason == .manual {
                haptics.captureStopped()
            }
        }

        tickerTask?.cancel()
        tickerTask = nil
        liveActivity?.stop()

        let recording = recorder?.stop()
        if !saving { recorder?.discardRecording() }
        recorder = nil

        if saving {
            // Файловым движкам запись передаётся здесь, потоковые просто
            // закрывают поток.
            await engine?.finishSession(audioFileURL: recording?.fileURL)
            await eventsTask?.value
        } else {
            eventsTask?.cancel()
            await engine?.cancelSession()
        }

        eventsTask = nil
        sessionManager.deactivate()

        var didSave = false
        if saving {
            didSave = await persistResult(duration: recording?.duration ?? elapsed)
        }

        engine = nil
        isFinishing = false

        if saving {
            // Фазу сбрасываем только при успехе: иначе затрём сообщение
            // об ошибке, которое пользователь ещё не увидел.
            if didSave { phase = .idle }
        } else {
            liveTranscript = ""
            audioLevel = 0
            elapsed = 0
            phase = .idle
        }
    }

    /// Убирает сообщение об ошибке.
    ///
    /// Ошибка записи это не состояние приложения, а событие: человек её
    /// прочитал и хочет вернуться к делам, а не ждать следующей записи,
    /// чтобы сообщение исчезло само.
    func dismissError() {
        guard case .failed = phase else { return }
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

        // Несохранённый захват не существует: сообщать о нём разбору
        // и синхронизации значит поставить в очередь запись, которой нет.
        guard save(context: "текстовый захват") else {
            modelContext.delete(capture)
            return nil
        }

        lastSavedCaptureID = capture.id
        onCaptureSaved?(capture)
        return capture
    }
}

// MARK: - Внутренняя механика

private extension CaptureCoordinator {

    /// Поднимает аудиосессию, движок распознавания и рекордер.
    ///
    /// После каждого ожидания проверяется, не устарела ли сессия: человек
    /// мог передумать, пока качалась модель или пока система спрашивала
    /// разрешение. Устаревший запуск обязан свернуть за собой всё, что
    /// успел создать, и не трогать состояние экрана.
    func beginSession(generation: Int) async throws {
        let engine = SpeechEngineFactory.make(preference: settings.enginePreference)
        self.engine = engine

        // Модель WhisperKit должна быть загружена до старта записи,
        // иначе первые секунды речи уйдут в пустоту.
        try await engine.prepare()
        guard generation == sessionGeneration else {
            await engine.cancelSession()
            self.engine = nil
            return
        }

        try sessionManager.activateForRecording()
        applyRoutePreset()

        let stream = try await engine.beginSession(locale: settings.resolvedLocale)
        guard generation == sessionGeneration else {
            await engine.cancelSession()
            sessionManager.deactivate()
            self.engine = nil
            return
        }

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

        guard generation == sessionGeneration else {
            recorder.stop()
            recorder.discardRecording()
            await engine.cancelSession()
            sessionManager.deactivate()
            self.engine = nil
            return
        }

        self.recorder = recorder
        startedAt = ProcessInfo.processInfo.systemUptime
        lastActivityUpdate = 0
        phase = .listening
        startTicker()

        // Динамический остров: пользователь говорит, глядя на дорогу или
        // на собеседника, и должен понимать периферийным зрением, что
        // микрофон слышит.
        liveActivity?.start()

        Log.voice.notice("""
            Захват начат: источник \(self.captureSource.rawValue, privacy: .public), \
            движок \(engine.kind.rawValue, privacy: .public)
            """)
    }

    /// Подстраивает детектор под текущий маршрут звука.
    ///
    /// Bluetooth-гарнитура в профиле HFP отдаёт сигнал заметно тише
    /// встроенного микрофона, а режим .measurement отключает системную
    /// обработку. С общими порогами запись через AirPods обрывалась через
    /// четыре секунды с «речь не распознана», хотя человек говорил.
    func applyRoutePreset() {
        guard sessionManager.isUsingBluetoothInput else { return }

        var configuration = settings.vadConfiguration
        configuration.speechThreshold *= 0.4
        configuration.silenceThreshold *= 0.4
        configuration.leadingSilenceTimeout += 2

        detector = VoiceActivityDetector(configuration: configuration)
        Log.voice.notice("Запись через Bluetooth: пороги детектора понижены")
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

                // Потолок длительности держится здесь, а не только
                // на аудиоколбэках: если поток буферов оборвался, детектор
                // молчит, и сессия висела бы бесконечно с включённым
                // микрофоном.
                if self.elapsed >= self.settings.vadConfiguration.maximumDuration {
                    await self.stop(reason: .maxDuration)
                    return
                }

                // Остров обновляется раз в секунду: система ограничивает
                // частоту и просто отбрасывает слишком частые запросы.
                if self.elapsed - self.lastActivityUpdate >= 1 {
                    self.lastActivityUpdate = self.elapsed
                    self.liveActivity?.update(
                        level: self.audioLevel,
                        transcript: self.liveTranscript,
                        isSpeaking: self.hasDetectedSpeech,
                        elapsed: self.elapsed
                    )
                }
            }
        }
    }

    /// Сохраняет результат сессии в базу.
    /// - Returns: удалось ли сохранить захват.
    @discardableResult
    func persistResult(duration: TimeInterval) async -> Bool {
        let text = (finalText ?? liveTranscript).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            // Текста нет, но звук может быть цел: распознавание Apple уходит
            // на сервер, если языковая модель не скачана, и в метро задача
            // просто не доезжает. Раньше в этом месте стиралось и то,
            // и другое, то есть тридцать секунд надиктовки исчезали
            // насовсем. Теперь запись остаётся, если человек хранит аудио.
            if settings.keepAudioRecordings,
               let recordingURL,
               FileManager.default.fileExists(atPath: recordingURL.path) {

                let capture = CaptureItem(
                    id: captureID,
                    text: "",
                    status: .failed,
                    source: captureSource,
                    engine: engine?.kind ?? .none,
                    languageCode: finalLanguage,
                    audioDuration: duration,
                    audioFileName: recordingURL.lastPathComponent
                )
                capture.failureReason = "Речь не распознана, запись голоса сохранена"

                modelContext.insert(capture)
                if save(context: "запись без расшифровки") {
                    lastSavedCaptureID = capture.id
                } else {
                    modelContext.delete(capture)
                }

                self.recordingURL = nil
                Log.voice.notice("Расшифровки нет, аудио сохранено")
                phase = .failed(.emptyTranscription)
                if settings.hapticsEnabled { haptics.captureFailed() }
                return false
            }

            // Аудио не хранится: держать файл незачем.
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

        // Раньше сбой сохранения выдавался за успех: пользователь получал
        // тактильное «сохранено», экран возвращался в покой, а записи
        // не было. Теперь неудача остаётся неудачей.
        guard save(context: "голосовой захват") else {
            modelContext.delete(capture)
            recordingURL = nil
            if settings.hapticsEnabled { haptics.captureFailed() }
            return false
        }

        lastSavedCaptureID = capture.id
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

    /// - Returns: удалось ли записать изменения на диск.
    @discardableResult
    func save(context: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            Log.data.error("Не удалось сохранить \(context, privacy: .public): \(error.localizedDescription)")
            phase = .failed(.persistenceFailed(underlying: error.localizedDescription))
            return false
        }
    }

    func fail(with error: AppError) {
        Log.voice.error("Захват прерван: \(error.localizedDescription)")
        phase = .failed(error)
        if settings.hapticsEnabled { haptics.captureFailed() }

        tickerTask?.cancel()
        tickerTask = nil
        liveActivity?.stop()

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
