import AppIntents
import Foundation

/// Быстрый голосовой захват: то, что вешается на кнопку действия.
///
/// Порядок внутри `perform` подчинён требованию отклика: тактильный сигнал
/// уходит первым, до любых проверок и ожиданий. Запись микрофона в фоне
/// система не разрешает, поэтому интент открывает приложение и сразу начинает
/// слушать, а пользователь успевает начать говорить ещё в момент анимации.
struct QuickCaptureIntent: AppIntent {

    static var title: LocalizedStringResource = "Быстрая запись"

    static var description = IntentDescription(
        "Мгновенно начинает запись голоса и сохраняет её в инбокс.",
        categoryName: "Захват"
    )

    /// Микрофон недоступен без активного приложения, поэтому открываем его.
    static var openAppWhenRun: Bool = true

    /// Показывать интент в поиске и на экране блокировки.
    static var isDiscoverable: Bool = true

    @Parameter(title: "Источник", default: .actionButton)
    var source: CaptureSourceAppValue

    init() {}

    init(source: CaptureSourceAppValue) {
        self.source = source
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Первое действие: тактильный отклик. Всё остальное после.
        let environment = AppEnvironment.shared
        if environment.settings.hapticsEnabled {
            HapticEngine.shared.captureStarted()
        }

        Log.intents.notice("QuickCaptureIntent: источник \(self.source.rawValue, privacy: .public)")

        // Повторное нажатие во время записи останавливает её: кнопка работает
        // как переключатель, это привычнее, чем игнорирование нажатия.
        if environment.coordinator.phase.isActive {
            await environment.coordinator.stop(reason: .manual)
            return .result()
        }

        await environment.coordinator.start(source: self.source.captureSource)
        return .result()
    }
}

/// Обёртка над CaptureSource для App Intents: системе нужен тип,
/// соответствующий AppEnum, а доменное перечисление не должно зависеть
/// от фреймворка интентов.
enum CaptureSourceAppValue: String, AppEnum {
    case actionButton
    case controlCenter
    case widget
    case siri

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Источник записи")

    static var caseDisplayRepresentations: [CaptureSourceAppValue: DisplayRepresentation] = [
        .actionButton: "Кнопка действия",
        .controlCenter: "Пункт управления",
        .widget: "Виджет",
        .siri: "Siri"
    ]

    var captureSource: CaptureSource {
        switch self {
        case .actionButton: return .actionButton
        case .controlCenter: return .controlCenter
        case .widget: return .widget
        case .siri: return .siri
        }
    }
}

/// Остановка текущей записи. Нужна для сценариев автоматизации
/// и как отдельная команда Siri.
struct StopCaptureIntent: AppIntent {

    static var title: LocalizedStringResource = "Остановить запись"

    static var description = IntentDescription(
        "Останавливает текущую голосовую запись и сохраняет результат.",
        categoryName: "Захват"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = AppEnvironment.shared.coordinator
        guard coordinator.phase.isActive else { return .result() }
        await coordinator.stop(reason: .manual)
        return .result()
    }
}
