import Foundation

/// Доменные ошибки приложения. Каждая несёт текст для пользователя и признак
/// того, можно ли повторить операцию: UI по нему решает, показывать кнопку «Повторить».
enum AppError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case speechRecognizerUnavailable(locale: String)
    case audioSessionFailed(underlying: String)
    case audioEngineFailed(underlying: String)
    case recognitionFailed(underlying: String)
    case emptyTranscription
    case whisperModelUnavailable
    case persistenceFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return String(localized: "error.microphone.denied")
        case .speechPermissionDenied:
            return String(localized: "error.speech.denied")
        case .speechRecognizerUnavailable(let locale):
            return String(localized: "error.speech.unavailable \(locale)")
        case .audioSessionFailed(let underlying):
            return String(localized: "error.audio.session \(underlying)")
        case .audioEngineFailed(let underlying):
            return String(localized: "error.audio.engine \(underlying)")
        case .recognitionFailed(let underlying):
            return String(localized: "error.recognition.failed \(underlying)")
        case .emptyTranscription:
            return String(localized: "error.transcription.empty")
        case .whisperModelUnavailable:
            return String(localized: "error.whisper.unavailable")
        case .persistenceFailed(let underlying):
            return String(localized: "error.persistence.failed \(underlying)")
        }
    }

    /// Ошибку прав нет смысла повторять: нужно вести пользователя в настройки.
    var isRetryable: Bool {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied:
            return false
        case .speechRecognizerUnavailable, .audioSessionFailed, .audioEngineFailed,
             .recognitionFailed, .emptyTranscription, .whisperModelUnavailable,
             .persistenceFailed:
            return true
        }
    }

    /// Нужно ли предлагать переход в системные настройки приложения.
    var suggestsSystemSettings: Bool {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied:
            return true
        default:
            return false
        }
    }
}
