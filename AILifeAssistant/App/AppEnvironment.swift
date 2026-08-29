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
    let undoService: UndoService
    let completionService: CompletionService
    let deletionService: DeletionService
    let changeTracker: ChangeTracker
    let liveActivity: LiveActivityController
    let notificationRouter: NotificationRouter
    let appLock: AppLock

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

        let liveActivity = LiveActivityController()
        self.liveActivity = liveActivity
        self.notificationRouter = NotificationRouter()
        self.appLock = AppLock()

        self.coordinator = CaptureCoordinator(
            modelContext: container.mainContext,
            permissions: permissions,
            settings: settings,
            recordingStore: recordingStore,
            liveActivity: liveActivity
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
            sessionProvider: {
                guard let token = auth.accessToken, let userID = auth.userID else { return nil }
                return SyncEngine.Session(accessToken: token, userID: userID)
            }
        )
        self.searchService = SearchService(
            modelContext: container.mainContext,
            networkMonitor: networkMonitor,
            sessionProvider: { auth.accessToken }
        )

        // Отмена последнего действия: пять секунд на передумать.
        // Объявляется до замыканий, которые её используют.
        let undo = UndoService(modelContext: container.mainContext)
        self.undoService = undo

        // Сохранённый захват сразу уходит в разбор и в очередь отправки.
        let queue = processingQueue
        let sync = syncEngine
        coordinator.onCaptureSaved = { capture in
            queue.enqueue(capture)
            sync.markChanged(.capture, id: capture.id)
            undo.register(captureCreated: capture)
        }

        // Исправление показывается тем же баннером: пользователь видит,
        // что именно поняло приложение из его поправки, и может вернуть
        // всё назад.
        processingQueue.onCorrectionApplied = { outcome in
            undo.register(correction: outcome)
        }

        // Отменённая запись не должна уехать на сервер как существующая.
        undo.onUndone = { action in
            guard case .captureCreated(let id) = action.kind else { return }
            sync.markDeleted(.capture, id: id)
        }

        // Возврат сети это повод не только синхронизироваться, но и
        // дорасшифровать: у облачного разбора могли остаться записи,
        // отложенные из-за отсутствия связи.
        networkMonitor.whenBecameOnline { [weak queue] in
            Task { @MainActor in
                await queue?.processPending()
            }
        }

        // Восстановленную запись нужно разобрать заново: вернулась она
        // пустой, без задач и расходов.
        undo.onCaptureRestored = { [weak queue] id in
            sync.markChanged(.capture, id: id)
            Task { @MainActor in
                await queue?.processPending()
            }
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

        // Закрытие дела: один путь для всех экранов и виджета.
        let completion = CompletionService(
            modelContext: container.mainContext,
            mirror: mirror,
            settings: settings,
            haptics: .shared
        )
        completion.onChanged = { entityType, id in
            sync.markChanged(entityType, id: id)
        }
        self.completionService = completion

        // Удаление: один путь на всё приложение, и сервер о нём узнаёт.
        let deletion = DeletionService(
            modelContext: container.mainContext,
            mirror: mirror
        )
        deletion.onDeleted = { entityType, id in
            sync.markDeleted(entityType, id: id)
        }
        self.deletionService = deletion
        undo.deletion = deletion

        // Правки с экранов доходят до сервера через один и тот же путь.
        self.changeTracker = ChangeTracker { entityType, id in
            sync.markChanged(entityType, id: id)
        }

        // Выход из аккаунта не должен оставлять следующему пользователю
        // очередь отправки и курсор от чужой сессии.
        auth.onSignOut = { [weak sync] in
            sync?.forgetSession()
        }

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
            //
            // В задачу уходят идентификаторы: разбор асинхронный, и записи
            // вполне может не стать к моменту постановки уведомления.
            let reminderIDs = capture.reminders.map(\.id)
            Task { @MainActor in
                for id in reminderIDs {
                    await mirror.register(reminderID: id)
                }
            }

            // Баннер обновляется на результат разбора: пока шёл разбор,
            // в нём был сырой текст, теперь видно, что создано. Именно
            // обновляется, а не создаётся заново: иначе разбор старых
            // записей при запуске предлагал бы их удалить, а быстрая
            // диктовка двух фраз подряд подменяла бы баннер.
            undo.updateSummary(for: capture)
        }

        // Делегат ставится сразу: нажатие на уведомление может быть тем самым
        // событием, которое запустило приложение, и опоздать здесь нельзя.
        notificationRouter.register()

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

            // Полный дамп дневника, который человек однажды выгрузил
            // и не отправил, не должен пережить перезапуск.
            await ExportService.removeStaleExports()
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
        let completionService: CompletionService
        let deletionService: DeletionService
    let changeTracker: ChangeTracker
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

        // Зеркалирование в тестах не поднимается: оно тянет за собой
        // EventKit и системные уведомления, которых в тестовой среде нет.
        let completion = CompletionService(
            modelContext: container.mainContext,
            settings: settings
        )
        let deletion = DeletionService(modelContext: container.mainContext)
        // Без обработчика: в тестах правки никуда не уезжают.
        let changes = ChangeTracker()

        return Testing(
            container: container,
            coordinator: coordinator,
            settings: settings,
            permissions: permissions,
            processingQueue: queue,
            completionService: completion,
            deletionService: deletion,
            changeTracker: changes
        )
    }
}
