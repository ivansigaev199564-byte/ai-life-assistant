import AppIntents

/// Готовые ярлыки, которые система показывает в Spotlight, приложении
/// «Команды» и предлагает для кнопки действия.
///
/// Фразы заданы на двух языках: продукт двуязычный, и Siri должна понимать
/// команду независимо от языка системы.
struct AILifeAssistantShortcuts: AppShortcutsProvider {

    /// Цвет плитки ярлыка в приложении «Команды».
    static var shortcutTileColor: ShortcutTileColor = .navy

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(source: .siri),
            phrases: [
                "Записать в \(.applicationName)",
                "Заметка в \(.applicationName)",
                "Быстрая запись в \(.applicationName)",
                "Capture in \(.applicationName)",
                "Quick note in \(.applicationName)"
            ],
            shortTitle: "Быстрая запись",
            systemImageName: "mic.circle.fill"
        )

        AppShortcut(
            intent: StopCaptureIntent(),
            phrases: [
                "Остановить запись в \(.applicationName)",
                "Stop capture in \(.applicationName)"
            ],
            shortTitle: "Остановить запись",
            systemImageName: "stop.circle.fill"
        )
    }
}
