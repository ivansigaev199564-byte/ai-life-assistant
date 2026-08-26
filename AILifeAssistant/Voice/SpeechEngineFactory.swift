import Foundation

/// Что выбрал пользователь в настройках распознавания.
enum SpeechEnginePreference: String, CaseIterable, Sendable {
    /// Приложение решает само: быстрый движок Apple.
    case automatic
    /// Явно Apple Speech.
    case appleSpeech
    /// Явно WhisperKit, с загрузкой модели.
    case whisperKit

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "engine.preference.automatic")
        case .appleSpeech: return String(localized: "engine.preference.apple")
        case .whisperKit: return String(localized: "engine.preference.whisper")
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return String(localized: "engine.preference.automatic.hint")
        case .appleSpeech: return String(localized: "engine.preference.apple.hint")
        case .whisperKit: return String(localized: "engine.preference.whisper.hint")
        }
    }
}

/// Создаёт движок распознавания под настройку пользователя и возможности устройства.
///
/// Здесь же живёт точка расширения для нового Speech API из iOS 26:
/// когда появится доступ к SDK, добавляется третья реализация протокола,
/// и остальной код менять не придётся.
@MainActor
enum SpeechEngineFactory {

    static func make(
        preference: SpeechEnginePreference,
        capabilities: Capabilities = .current
    ) -> SpeechRecognizing {
        switch preference {
        case .whisperKit:
            #if canImport(WhisperKit)
            return WhisperKitRecognizer()
            #else
            Log.voice.notice("WhisperKit недоступен в сборке, откат на Apple Speech")
            return AppleSpeechRecognizer()
            #endif

        case .appleSpeech, .automatic:
            // TODO(Этап 1.1): на устройствах с capabilities.hasModernSpeechAPI
            // подключить SpeechAnalyzer из iOS 26. Реализация добавляется
            // отдельным типом SpeechRecognizing после сверки сигнатур в Xcode 26:
            // писать её вслепую нельзя, API нового фреймворка нужно проверить
            // по заголовкам SDK.
            return AppleSpeechRecognizer()
        }
    }

    /// Язык распознавания для движков, которым нужна явная локаль.
    ///
    /// Порядок выбора: явная настройка пользователя, затем язык интерфейса,
    /// затем русский как язык по умолчанию для этого продукта.
    static func resolveLocale(preferredIdentifier: String?) -> Locale {
        if let preferredIdentifier, !preferredIdentifier.isEmpty {
            let locale = Locale(identifier: preferredIdentifier)
            if AppleSpeechRecognizer.supports(locale: locale) { return locale }
        }

        let systemLocale = Locale.current
        if AppleSpeechRecognizer.supports(locale: systemLocale) { return systemLocale }

        let russian = Locale(identifier: "ru-RU")
        if AppleSpeechRecognizer.supports(locale: russian) { return russian }

        return Locale(identifier: "en-US")
    }

    /// Языки, которые есть на устройстве, для выбора в настройках.
    /// Ограничиваем русским и английским: продукт двуязычный.
    static var availableLocales: [Locale] {
        ["ru-RU", "en-US", "en-GB"]
            .map(Locale.init(identifier:))
            .filter(AppleSpeechRecognizer.supports(locale:))
    }
}
