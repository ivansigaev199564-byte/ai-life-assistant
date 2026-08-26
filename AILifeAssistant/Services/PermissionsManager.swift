import AVFoundation
import Foundation
import Observation
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// Состояние всех разрешений, нужных для голосового захвата.
@MainActor
@Observable
final class PermissionsManager {

    enum Status: Equatable, Sendable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    private(set) var microphone: Status = .notDetermined
    private(set) var speechRecognition: Status = .notDetermined

    /// Можно ли начинать запись прямо сейчас.
    var isReadyForCapture: Bool {
        microphone == .granted && speechRecognition == .granted
    }

    /// Есть ли отказ, который лечится только походом в Настройки.
    var requiresSystemSettings: Bool {
        microphone == .denied || speechRecognition == .denied
            || microphone == .restricted || speechRecognition == .restricted
    }

    init() {
        refresh()
    }

    /// Читает текущее состояние без показа системных запросов.
    func refresh() {
        microphone = Self.map(AVAudioApplication.shared.recordPermission)
        speechRecognition = Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    /// Запрашивает оба разрешения по очереди.
    ///
    /// Микрофон спрашиваем первым: без него распознавание бессмысленно,
    /// и два системных окна подряд выглядят логично именно в таком порядке.
    @discardableResult
    func requestAll() async -> Bool {
        if microphone == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            microphone = granted ? .granted : .denied
        }

        guard microphone == .granted else {
            Log.voice.notice("Микрофон не разрешён, запрос распознавания пропущен")
            return false
        }

        if speechRecognition == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            speechRecognition = Self.map(status)
        }

        return isReadyForCapture
    }

    /// Ошибка, которую нужно показать пользователю, если запись невозможна.
    var blockingError: AppError? {
        if microphone != .granted { return .microphonePermissionDenied }
        if speechRecognition != .granted { return .speechPermissionDenied }
        return nil
    }

    /// Открывает системные настройки приложения.
    func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: Преобразование системных статусов

    private static func map(_ permission: AVAudioApplication.recordPermission) -> Status {
        switch permission {
        case .undetermined: return .notDetermined
        case .granted: return .granted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}
