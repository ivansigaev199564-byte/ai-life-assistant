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

    /// Приложение запущено как хост юнит-тестов.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    let container: ModelContainer
    let settings: AppSettings
    let permissions: PermissionsManager
    let capabilities: Capabilities
    let recordingStore: RecordingStore
    let coordinator: CaptureCoordinator
    let processingQueue: ProcessingQueue
    let apiConfiguration: APIConfiguration

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

        // Облако выключено до появления функции-посредника: ключ модели
        // не должен лежать в приложении, поэтому пока работают только
        // локальные движки разбора.
        let apiConfiguration = APIConfiguration.default
        self.apiConfiguration = apiConfiguration
        self.processingQueue = ProcessingQueue(
            modelContext: container.mainContext,
            pipeline: ParsingPipeline.make(
                capabilities: capabilities,
                configuration: apiConfiguration
            )
        )

        // Сохранённый захват сразу уходит в разбор.
        let queue = processingQueue
        coordinator.onCaptureSaved = { capture in
            queue.enqueue(capture)
        }

        Log.capabilities.notice("Возможности устройства:\n\(self.capabilities.debugSummary, privacy: .public)")
    }

    /// Обслуживание при запуске: чистим старые записи, прогреваем тактильный движок.
    func performStartupMaintenance() {
        // Под тестами приложение-хост не должен выполнять фоновую работу:
        // она конкурирует с тестами за то же хранилище и роняет прогон.
        guard !Self.isRunningTests else { return }

        HapticEngine.shared.prewarm()

        Task.detached(priority: .utility) {
            let store = RecordingStore()
            store.pruneOldRecordings()
        }

        // Захваты, которые не успели разобраться в прошлый раз.
        Task { [processingQueue] in
            await processingQueue.processPending()
        }
    }

    /// Тестовое окружение с базой в памяти и изолированными настройками.
    struct Testing {
        let container: ModelContainer
        let coordinator: CaptureCoordinator
        let settings: AppSettings
        let permissions: PermissionsManager
        let processingQueue: ProcessingQueue
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
            settings: settings,
            // Тестам аудио не нужно: подписка на системные события
            // держит аудиостек и роняет прогон при пересоздании.
            sessionManager: AudioSessionManager(observesSystemEvents: false)
        )
        // В тестах работает только локальный разбор: сети у тестов нет.
        let queue = ProcessingQueue(
            modelContext: container.mainContext,
            pipeline: ParsingPipeline()
        )
        coordinator.onCaptureSaved = { capture in
            queue.enqueue(capture)
        }

        return Testing(
            container: container,
            coordinator: coordinator,
            settings: settings,
            permissions: permissions,
            processingQueue: queue
        )
    }
}
