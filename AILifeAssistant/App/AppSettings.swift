import Foundation
import Observation

/// Пользовательские настройки захвата.
///
/// Хранятся в UserDefaults группы приложения: к ним обращается и основное
/// приложение, и расширения (App Intents, Share Extension на Этапе 4).
@MainActor
@Observable
final class AppSettings {

    /// Группа приложений. Одна на всё приложение и расширения.
    static let suiteName = SharedDefaults.suiteName

    private let defaults: UserDefaults

    private enum Key {
        static let enginePreference = "settings.speech.engine"
        static let localeIdentifier = "settings.speech.locale"
        static let dictationMode = "settings.vad.dictation"
        static let keepAudio = "settings.audio.keep"
        static let hapticsEnabled = "settings.haptics.enabled"
        static let hasCompletedOnboarding = "settings.onboarding.done"
    }

    init(defaults: UserDefaults? = nil) {
        // Если группа не сконфигурирована, откатываемся на стандартные
        // настройки: приложение должно работать и без App Group.
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard

        self.enginePreference = SpeechEnginePreference(
            rawValue: self.defaults.string(forKey: Key.enginePreference) ?? ""
        ) ?? .automatic
        self.localeIdentifier = self.defaults.string(forKey: Key.localeIdentifier)
        self.isDictationMode = self.defaults.bool(forKey: Key.dictationMode)
        self.keepAudioRecordings = self.defaults.object(forKey: Key.keepAudio) as? Bool ?? true
        self.hapticsEnabled = self.defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        self.hasCompletedOnboarding = self.defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    /// Какой движок распознавания использовать.
    var enginePreference: SpeechEnginePreference {
        didSet { defaults.set(enginePreference.rawValue, forKey: Key.enginePreference) }
    }

    /// Язык распознавания. nil означает «как в системе».
    var localeIdentifier: String? {
        didSet { defaults.set(localeIdentifier, forKey: Key.localeIdentifier) }
    }

    /// Режим длинной надиктовки: детектор тишины ждёт дольше.
    var isDictationMode: Bool {
        didSet { defaults.set(isDictationMode, forKey: Key.dictationMode) }
    }

    /// Хранить ли аудиофайлы после распознавания.
    var keepAudioRecordings: Bool {
        didSet { defaults.set(keepAudioRecordings, forKey: Key.keepAudio) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Конфигурация детектора под текущий режим.
    var vadConfiguration: VoiceActivityDetector.Configuration {
        isDictationMode ? .dictation : .default
    }

    /// Локаль для движков, которым нужна явная подсказка языка.
    var resolvedLocale: Locale {
        SpeechEngineFactory.resolveLocale(preferredIdentifier: localeIdentifier)
    }
}
