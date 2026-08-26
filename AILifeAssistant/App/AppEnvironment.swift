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
    let networkMonitor: NetworkMonitor
    let auth: AuthService
    let syncEngine: SyncEngine
    let searchService: SearchService
    let notifications: NotificationService
    let eventKit: EventKitService
    let reminderMirror: ReminderMirror

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

        // Сеть, вход и синхронизация. Бэкенд может быть не настроен:
        // тогда всё это остаётся в покое, а приложение работает локально.
        let networkMonitor = NetworkMonitor()
        let auth = AuthService()
        let syncQueue = SyncQueue()

        self.networkMonitor = networkMonitor
        self.auth = auth
        self.syncEngine = SyncEngine(
            modelContext: container.mainContext,
            queue: syncQueue,
            networkMonitor: networkMonitor,
            sessionProvider: { auth.accessToken }
        )
        self.searchService = SearchService(
            modelContext: container.mainContext,
            networkMonitor: networkMonitor,
            sessionProvider: { auth.accessToken }
        )

        // Сохранённый захват сразу уходит в разбор и в очередь отправки.
        let queue = processingQueue
        let sync = syncEngine
        coordinator.onCaptureSaved = { capture in
            queue.enqueue(capture)
            sync.markChanged(.capture, id: capture.id)
        }

        // Системные интеграции: уведомления и зеркалирование напоминаний.
        let notifications = NotificationService()
        let eventKit = EventKitService()
        let mirror = ReminderMirror(
            modelContext: container.mainContext,
            notifications: notifications,
            eventKit: eventKit
        )

        self.notifications = notifications
        self.eventKit = eventKit
        self.reminderMirror = mirror

        // Разбор породил сущности: их нужно отправить на сервер
        // и превратить напоминания в реальные уведомления.
        processingQueue.onEntitiesMaterialized = { capture in
            sync.markChanged(.capture, id: capture.id)
            capture.notes.forEach { sync.markChanged(.note, id: $0.id) }
            capture.tasks.forEach { sync.markChanged(.task, id: $0.id) }
            capture.reminders.forEach { sync.markChanged(.reminder, id: $0.id) }
            capture.expenses.forEach { sync.markChanged(.expense, id: $0.id) }

            // Напоминание без уведомления это обещание, которое приложение
            // не выполнит: телефон просто промолчит в нужный момент.
            let newReminders = capture.reminders
            Task { @MainActor in
                for reminder in newReminders {
                    await mirror.register(reminder)
                }
            }
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

        // Синхронизация, если бэкенд настроен и есть сессия.
        Task { [auth, syncEngine] in
            await auth.refreshIfNeeded()
            await syncEngine.sync()
        }

        // Расписание уведомлений и закрытые в системе дела.
        Task { [reminderMirror] in
            await reminderMirror.refreshSchedule()
            await reminderMirror.pullCompletions()
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
        // Очередь создаётся, но к координатору не подключается: фоновая
        // задача разбора переживает тест, а контейнер к тому моменту уже
        // уничтожен. Тесты разбора работают с конвейером напрямую.
        let queue = ProcessingQueue(
            modelContext: container.mainContext,
            pipeline: ParsingPipeline()
        )

        return Testing(
            container: container,
            coordinator: coordinator,
            settings: settings,
            permissions: permissions,
            processingQueue: queue
        )
    }
}
