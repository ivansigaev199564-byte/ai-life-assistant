import AVFoundation
import Foundation

/// Захват звука с микрофона: считает уровень сигнала, раздаёт буферы
/// распознавателю и параллельно пишет файл на диск.
///
/// Файл нужен по двум причинам: WhisperKit работает по файлу, а пользователь
/// на Этапе 5 сможет переслушать спорную запись.
final class AudioEngineRecorder: @unchecked Sendable {

    struct Result: Sendable {
        let fileURL: URL?
        let duration: TimeInterval
        let peakLevel: Float
    }

    /// Буферы для распознавателя. Вызывается на аудиопотоке.
    var onBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Уровень 0...1 и монотонное время замера. Вызывается на аудиопотоке.
    var onLevel: (@Sendable (Float, TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    /// Очередь записи на диск.
    ///
    /// Колбэк tap приходит из потока реального времени: любая блокировка
    /// в нём это риск подрезанного звука. Файловая запись под замком там
    /// была прямым нарушением этого правила, поэтому буфер копируется
    /// и уезжает сюда.
    private let writeQueue = DispatchQueue(label: "com.ivans.ailifeassistant.recorder.write", qos: .utility)

    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var startedAt: TimeInterval?
    private var peak: Float = 0
    private var isRunning = false

    /// Размер буфера. 2048 кадров при 48 кГц дают замер примерно каждые 43 мс:
    /// достаточно часто для отзывчивого детектора тишины и не грузит процессор.
    private let bufferSize: AVAudioFrameCount = 2048

    /// Запускает движок.
    /// - Parameter recordingURL: куда писать файл. nil означает «без записи на диск».
    func start(recordingURL: URL?) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Нулевая частота означает, что железо ещё не отдало микрофон:
        // так бывает при старте во время звонка.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError.audioEngineFailed(underlying: "Микрофон недоступен")
        }

        if let recordingURL {
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                audioFile = try AVAudioFile(forWriting: recordingURL, settings: settings)
                fileURL = recordingURL
            } catch {
                Log.voice.error("Не удалось создать файл записи: \(error.localizedDescription)")
                // Запись на диск не критична: продолжаем без файла.
                audioFile = nil
                fileURL = nil
            }
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            throw AppError.audioEngineFailed(underlying: error.localizedDescription)
        }

        startedAt = ProcessInfo.processInfo.systemUptime
        peak = 0
        isRunning = true
        Log.voice.debug("Аудиодвижок запущен: \(format.sampleRate) Гц, \(format.channelCount) кан.")
    }

    /// Переустанавливает отвод под новый маршрут звука.
    ///
    /// Подключение гарнитуры посреди фразы меняет частоту дискретизации
    /// и число каналов, а отвод остаётся настроенным на прежний формат:
    /// буферы либо перестают приходить, либо приходят мусором. Раньше
    /// на это событие запись просто останавливалась, теперь она
    /// продолжается на новом устройстве.
    ///
    /// - Returns: удалось ли перезапустить захват.
    @discardableResult
    func restartForRouteChange() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return false }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.voice.error("Новый маршрут не отдал формат, запись остановлена")
            isRunning = false
            return false
        }

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.voice.error("Движок не перезапустился: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            isRunning = false
            return false
        }

        Log.voice.notice("Отвод переустановлен: \(format.sampleRate) Гц, \(format.channelCount) кан.")
        return true
    }

    /// Останавливает движок и закрывает файл.
    @discardableResult
    func stop() -> Result {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else {
            return Result(fileURL: fileURL, duration: 0, peakLevel: peak)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        let duration = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let result = Result(fileURL: fileURL, duration: duration, peakLevel: peak)

        // Ждём, пока очередь допишет накопленное, и закрываем файл:
        // AVAudioFile дописывает заголовок в deinit.
        writeQueue.sync { audioFile = nil }
        startedAt = nil

        Log.voice.debug("Аудиодвижок остановлен, длительность \(duration, format: .fixed(precision: 2)) с")
        return result
    }

    /// Удаляет файл незавершённой записи, если она оказалась пустой.
    func discardRecording() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        self.fileURL = nil
    }

    // MARK: Обработка буфера

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        onBuffer?(buffer, time)

        // Буфер tap живёт только внутри колбэка, поэтому на очередь уходит
        // копия, а не он сам.
        if audioFile != nil, let copy = Self.copy(of: buffer) {
            writeQueue.async { [weak self] in
                guard let self, let file = self.audioFile else { return }
                do {
                    try file.write(from: copy)
                } catch {
                    Log.voice.error("Ошибка записи в файл: \(error.localizedDescription)")
                }
            }
        }

        let level = Self.rms(of: buffer)
        lock.lock()
        peak = max(peak, level)
        lock.unlock()

        onLevel?(level, ProcessInfo.processInfo.systemUptime)
    }

    /// Копия буфера: содержимое tap-буфера переиспользуется системой сразу
    /// после возврата из колбэка.
    private static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }

        copy.frameLength = buffer.frameLength

        guard let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
            return nil
        }

        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], bytes)
        }
        return copy
    }

    deinit {
        // Владелец мог исчезнуть, не остановив запись. Без снятия tap
        // микрофон остаётся открытым, и телефон продолжает показывать,
        // что приложение слушает.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Среднеквадратичный уровень первого канала, приведённый к 0...1.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let samples = channelData[0]

        var sum: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sum += sample * sample
        }
        let mean = sum / Float(frames)
        return mean > 0 ? sqrt(mean) : 0
    }
}
