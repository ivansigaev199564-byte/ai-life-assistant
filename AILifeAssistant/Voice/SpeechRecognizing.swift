import AVFoundation
import Foundation

/// Текстовые события распознавания.
///
/// Уровень сигнала сюда намеренно не входит: он приходит из рекордера,
/// общего для всех движков, и до распознавателя не доходит.
enum TranscriptionEvent: Sendable, Equatable {
    /// Промежуточный текст по ходу речи.
    case partial(String)
    /// Итоговый текст с уверенностью 0...1 и определённым языком.
    case final(text: String, confidence: Double, languageCode: String?)
    /// Ошибка, после неё поток закрывается.
    case failed(AppError)
}

/// Почему запись завершилась.
enum SpeechFinishReason: String, Sendable, Equatable {
    case manual
    case silence
    case maxDuration
    case noSpeech
    case interrupted
}

/// Единый интерфейс движков распознавания.
///
/// Микрофоном владеет `AudioEngineRecorder`, движок только потребляет звук:
/// потоковые движки принимают буферы через `append`, файловые получают
/// готовую запись в `finishSession`.
@MainActor
protocol SpeechRecognizing: AnyObject, Sendable {

    /// Какой движок стоит за реализацией, пишется в CaptureItem.
    var kind: SpeechEngineKind { get }

    /// Отдаёт ли текст по ходу речи.
    var supportsPartialResults: Bool { get }

    /// Определяет язык сам, без подсказки локалью.
    var supportsAutomaticLanguageDetection: Bool { get }

    /// Нужен ли движку файл записи. Для WhisperKit это единственный вход.
    var requiresAudioFile: Bool { get }

    /// Загрузка моделей и проверка разрешений до начала записи.
    func prepare() async throws

    /// Открывает сессию распознавания и возвращает поток событий.
    func beginSession(locale: Locale) async throws -> AsyncStream<TranscriptionEvent>

    /// Приём аудиобуфера. Вызывается с аудиопотока, поэтому вне изоляции актора.
    nonisolated func append(buffer: AVAudioPCMBuffer)

    /// Завершает сессию. Файловые движки начинают распознавание именно здесь.
    func finishSession(audioFileURL: URL?) async

    /// Прерывает сессию без результата.
    func cancelSession() async
}

extension SpeechRecognizing {
    func prepare() async throws {}
    var requiresAudioFile: Bool { false }
}
