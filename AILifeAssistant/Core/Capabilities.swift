import Foundation

/// Единая точка правды о том, что доступно на конкретном устройстве.
///
/// Собирает две оси вместе: версию системы и железо. Весь остальной код
/// спрашивает у этого типа, а не пишет проверки доступности у себя.
struct Capabilities: Sendable, Equatable {

    /// Механизм захвата, доступный пользователю как основной.
    enum PrimaryCaptureTrigger: String, Sendable {
        /// Кнопка действия на iPhone 15 Pro и новее.
        case actionButton
        /// Элемент в Пункте управления, доступен с iOS 18.
        case controlCenter
        /// Виджет на экране блокировки или ярлык Siri.
        case widgetOrShortcut
    }

    /// Какой движок разбора команд доступен на устройстве.
    enum OnDeviceParsing: String, Sendable {
        /// Foundation Models: локальная модель со структурированным выводом.
        case foundationModels
        /// Регулярные выражения плюс NaturalLanguage. Работает везде.
        case heuristics
    }

    let device: DeviceCapabilities

    /// Новый Speech API (SpeechAnalyzer) существует начиная с iOS 26.
    let hasModernSpeechAPI: Bool

    /// Foundation Models: нужны и версия системы, и подходящее железо.
    let hasFoundationModels: Bool

    /// Элементы Пункта управления доступны с iOS 18, то есть на всём нашем диапазоне.
    let hasControlCenterControls: Bool

    /// Живые активности и Динамический остров.
    let hasLiveActivities: Bool

    init(device: DeviceCapabilities = .current, osVersion: OperatingSystemVersion? = nil) {
        let version = osVersion ?? ProcessInfo.processInfo.operatingSystemVersion
        self.device = device
        self.hasModernSpeechAPI = version.majorVersion >= 26
        self.hasFoundationModels = version.majorVersion >= 26 && device.supportsAppleIntelligenceHardware
        self.hasControlCenterControls = version.majorVersion >= 18
        self.hasLiveActivities = device.hasDynamicIsland
    }

    /// Основная точка входа для захвата: то, что показываем в онбординге
    /// и подсказках, чтобы не предлагать пользователю несуществующую кнопку.
    var primaryTrigger: PrimaryCaptureTrigger {
        if device.hasActionButton { return .actionButton }
        if hasControlCenterControls { return .controlCenter }
        return .widgetOrShortcut
    }

    var onDeviceParsing: OnDeviceParsing {
        hasFoundationModels ? .foundationModels : .heuristics
    }

    static let current = Capabilities()

    /// Строка для логов и экрана диагностики в настройках.
    var debugSummary: String {
        """
        модель: \(device.modelIdentifier)
        Action Button: \(device.hasActionButton)
        Dynamic Island: \(device.hasDynamicIsland)
        современный Speech API: \(hasModernSpeechAPI)
        Foundation Models: \(hasFoundationModels)
        Пункт управления: \(hasControlCenterControls)
        основной триггер: \(primaryTrigger.rawValue)
        разбор на устройстве: \(onDeviceParsing.rawValue)
        """
    }
}
