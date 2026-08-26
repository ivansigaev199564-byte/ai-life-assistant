import Foundation
import SwiftData

/// Сборка зависимостей приложения.
///
/// Существует в единственном экземпляре, потому что к тем же сервисам
/// обращаются App Intents: интент выполняется в процессе приложения и должен
/// попасть в тот же координатор захвата, что и интерфейс.
@MainActor
final class AppEnvironment {

    static let shared = AppEnvironment()

    let container: ModelContainer
    let settings: AppSettings
    let permissions: PermissionsManager
    let capabilities: Capabilities
    let recordingStore: RecordingStore
    let coordinator: CaptureCoordinator

    private init() {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
        } catch {
            // Без хранилища приложение бессмысленно: показать пустой экран
            // хуже, чем упасть с понятным сообщением в отчёте о сбое.
            fatalError("Не удалось создать хранилище: \(error.localizedDescription)")
        }

        self.container = container
        self.settings = AppSettings()
        self.permissions = PermissionsManager()
        self.capabilities = .current
        self.recordingStore = RecordingStore()
        self.coordinator = CaptureCoordinator(
            modelContext: container.mainContext,
            permissions: permissions,
            settings: settings,
            recordingStore: recordingStore
        )

        Log.capabilities.notice("Возможности устройства:\n\(self.capabilities.debugSummary, privacy: .public)")
    }

    /// Обслуживание при запуске: чистим старые записи, прогреваем тактильный движок.
    func performStartupMaintenance() {
        HapticEngine.shared.prewarm()

        Task.detached(priority: .utility) {
            let store = RecordingStore()
            store.pruneOldRecordings()
        }
    }

    /// Тестовое окружение с базой в памяти и изолированными настройками.
    struct Testing {
        let container: ModelContainer
        let coordinator: CaptureCoordinator
        let settings: AppSettings
        let permissions: PermissionsManager
    }

    static func makeForTesting() -> Testing {
        let container = Persistence.makePreviewContainer()
        // Отдельный домен UserDefaults: тесты не должны затирать
        // настройки пользователя и друг друга.
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        let permissions = PermissionsManager()
        let coordinator = CaptureCoordinator(
            modelContext: container.mainContext,
            permissions: permissions,
            settings: settings
        )
        return Testing(
            container: container,
            coordinator: coordinator,
            settings: settings,
            permissions: permissions
        )
    }
}
