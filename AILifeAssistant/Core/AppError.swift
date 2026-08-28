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
