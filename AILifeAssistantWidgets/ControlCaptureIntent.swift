import AppIntents

/// Интент кнопки в Пункте управления.
///
/// Намеренно пустой: он только открывает приложение. Полный интент захвата
/// живёт в приложении и тянет за собой хранилище, аудио и разбор, а виджету
/// всё это загружать нельзя, у него жёсткий лимит памяти и он обязан
/// отрисоваться мгновенно.
///
/// Приложение, увидев запуск с этим источником, само начинает запись.
struct ControlCaptureIntent: AppIntent {

    static var title: LocalizedStringResource = "Быстрая запись"

    static var description = IntentDescription(
        "Открывает AI Assistant и начинает голосовую запись."
    )

    /// Микрофон недоступен без активного приложения, поэтому открываем его.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Флаг кладётся в общие настройки: приложение читает его, когда
        // оказывается на экране, и начинает запись с правильным источником.
        SharedDefaults.requestCapture()
        return .result()
    }
}
