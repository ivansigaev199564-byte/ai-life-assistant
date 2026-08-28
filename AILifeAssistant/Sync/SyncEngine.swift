import Foundation
import Observation
import SwiftData

/// Двусторонняя синхронизация локальной базы с сервером.
///
/// Приложение офлайн-первое: запись создаётся и разбирается на устройстве
/// независимо от связи, а синхронизация догоняет позже. Отсюда два правила,
/// которым подчинён весь этот тип.
///
/// Первое: локальная база это источник истины для того, что пользователь
/// только что сделал. Серверная копия принимается, только если она новее.
///
/// Второе: ни одна ошибка сети не должна терять данные. Неотправленное
/// остаётся в очереди и уезжает при следующей попытке.
@MainActor
@Observable
final class SyncEngine {

    enum State: Equatable {
        case idle
        case syncing
        case offline
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var pendingCount = 0

    private let modelContext: ModelContext
    private let queue: SyncQueue
    private let networkMonitor: NetworkMonitor
    private let sessionProvider: () -> Session?

    /// Как разговаривать с сервером.
    ///
    /// Замыкание, а не готовый объект: транспорт зависит от текущего токена,
    /// который меняется при входе и обновлении сессии. В тестах сюда
    /// подставляется фейк, и слой наконец стало возможно проверить.
    private let transportProvider: (Session) -> SyncTransport?

    /// Кто мы для сервера. Токен без идентификатора бесполезен: колонка
    /// владельца на сервере обязательная.
    struct Session: Sendable {
        let accessToken: String
        let userID: UUID
    }

    /// Ключ отметки последней синхронизации.
    private static let lastSyncKey = "sync.lastSyncedAt"

    /// Настройки бэкенда. Раньше читались статически из Bundle, поэтому
    /// в тестовом окружении всегда были пустыми, и любой тест на sync()
    /// выходил на первой же проверке, ничего не проверив.
    private let configuration: SupabaseConfiguration?

    init(
        modelContext: ModelContext,
        queue: SyncQueue,
        networkMonitor: NetworkMonitor,
        sessionProvider: @escaping () -> Session?,
        transportProvider: ((Session) -> SyncTransport?)? = nil,
        configuration: SupabaseConfiguration? = SupabaseConfiguration.current
    ) {
        self.modelContext = modelContext
        self.queue = queue
        self.networkMonitor = networkMonitor
        self.sessionProvider = sessionProvider
        self.configuration = configuration
        self.transportProvider = transportProvider ?? { session in
            guard let configuration else { return nil }
            return SupabaseRESTClient(
                configuration: configuration,
                accessToken: session.accessToken
            )
        }
        self.lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date

        networkMonitor.onBecameOnline = { [weak self] in
            guard let self else { return }
            // Прошлые неудачи были из-за отсутствия связи, а не из-за данных.
            self.queue.resetAttempts()
            Task { await self.sync() }
        }
    }

    /// Настроен ли бэкенд и есть ли сессия.
    var isReady: Bool {
        guard let session = sessionProvider() else { return false }
        return transportProvider(session) != nil
    }

    // MARK: Основной цикл

    /// Полный цикл: отправить своё, забрать чужое.
    func sync() async {
        guard isReady else {
            state = .idle
            return
        }
        guard networkMonitor.isOnline else {
            state = .offline
            return
        }
        guard state != .syncing else { return }

        state = .syncing

        do {
            try await push()
            let cursor = try await pull()

            // Отметка берётся из принятых данных. Раньше сюда писалось
            // локальное «сейчас», которое сравнивалось с серверным
            // временем: на телефоне с часами, ушедшими вперёд, чужие
            // изменения этих минут не запрашивались уже никогда.
            if let cursor {
                lastSyncedAt = cursor
                UserDefaults.standard.set(cursor, forKey: Self.lastSyncKey)
            }
            pendingCount = queue.pendingCount
            state = .idle

            Log.data.notice("Синхронизация завершена, в очереди осталось \(self.queue.pendingCount)")
        } catch let error as SupabaseRESTClient.ClientError {
            state = .failed(error.errorDescription ?? "Ошибка синхронизации")
            Log.data.error("Синхронизация не удалась: \(error.localizedDescription)")
        } catch {
            state = .failed(error.localizedDescription)
            Log.data.error("Синхронизация не удалась: \(error.localizedDescription)")
        }
    }

    /// Ставит запись в очередь на отправку.
    func markChanged(_ entityType: SyncEntityType, id: UUID) {
        queue.enqueue(entityType, id: id, kind: .upsert)
        pendingCount = queue.pendingCount
    }

    func markDeleted(_ entityType: SyncEntityType, id: UUID) {
        queue.enqueue(entityType, id: id, kind: .delete)
        pendingCount = queue.pendingCount
    }

    /// Забывает всё, что связано с прошлой сессией.
    ///
    /// Вызывается при выходе из аккаунта: очередь отправки и курсор
    /// принадлежат конкретному пользователю, и оставлять их следующему
    /// значит отправить его записи в чужой аккаунт.
    func forgetSession() {
        queue.clear()
        pendingCount = 0
        lastSyncedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        state = .idle
        Log.data.notice("Состояние синхронизации сброшено")
    }
}

// MARK: - Отправка

private extension SyncEngine {

    var client: SyncTransport? {
        guard let session = sessionProvider() else { return nil }
        return transportProvider(session)
    }

    /// Отправляет локальные изменения пачками по типам сущностей.
    ///
    /// Пачками, а не по одной записи: сотня отдельных запросов на первой
    /// синхронизации после установки съест и трафик, и лимиты сервера.
    func push() async throws {
        guard let client else { throw SupabaseRESTClient.ClientError.notConfigured }
        guard let userID = sessionProvider()?.userID else {
            throw SupabaseRESTClient.ClientError.notConfigured
        }

        let operations = queue.next(limit: 200)
        guard !operations.isEmpty else { return }

        let grouped = Dictionary(grouping: operations, by: \.entityType)

        for (entityType, typeOperations) in grouped {
            let upserts = typeOperations.filter { $0.kind == .upsert }
            let deletions = typeOperations.filter { $0.kind == .delete }

            if !upserts.isEmpty {
                let ids = Set(upserts.map(\.entityID))
                do {
                    try await pushEntities(of: entityType, ids: ids, using: client, userID: userID)
                    upserts.forEach(queue.complete)
                } catch {
                    // Записи остаются в очереди и уедут при следующей попытке:
                    // ошибка сети не должна терять данные.
                    upserts.forEach(queue.fail)
                    throw error
                }
            }

            // Удаления раньше молча отбрасывались: они не отправлялись,
            // не завершались и не помечались неудачными, то есть висели
            // в очереди вечно, а запись на сервере оставалась живой
            // и возвращалась на второе устройство.
            if !deletions.isEmpty {
                let ids = Set(deletions.map(\.entityID))
                do {
                    try await client.markDeleted(ids: ids, in: entityType.tableName)
                    deletions.forEach(queue.complete)
                } catch {
                    deletions.forEach(queue.fail)
                    throw error
                }
            }
        }

        pendingCount = queue.pendingCount
    }

    /// Собирает записи нужного типа и отправляет их на сервер.
    func pushEntities(
        of entityType: SyncEntityType,
        ids: Set<UUID>,
        using client: SyncTransport,
        userID: UUID
    ) async throws {
        switch entityType {
        case .capture:
            let items = try modelContext.fetch(
                FetchDescriptor<CaptureItem>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            markSynced(items)

        case .note:
            let items = try modelContext.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .task:
            let items = try modelContext.fetch(
                FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .reminder:
            let items = try modelContext.fetch(
                FetchDescriptor<Reminder>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .expense:
            let items = try modelContext.fetch(
                FetchDescriptor<Expense>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .person:
            let items = try modelContext.fetch(
                FetchDescriptor<Person>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .project:
            let items = try modelContext.fetch(
                FetchDescriptor<Project>(predicate: #Predicate { ids.contains($0.id) })
            )
            try await client.upsert(items.map { $0.dto(userID: userID) }, into: entityType.tableName)
            items.forEach { $0.syncState = .synced }
        }

        try modelContext.save()
    }

    func markSynced(_ items: [CaptureItem]) {
        for item in items {
            item.syncState = .synced
            item.lastSyncedAt = .now
        }
    }

}

// MARK: - Получение

private extension SyncEngine {

    /// Забирает всё, что изменилось на сервере после прошлой синхронизации.
    ///
    /// Порядок типов не случаен: люди и проекты идут первыми, затем захваты,
    /// и только потом производные сущности. Иначе заметка приедет раньше
    /// захвата, из которого сделана, и связь окажется пустой.
    /// - Returns: самая свежая отметка времени среди принятых записей.
    ///   Курсор берётся из данных, а не с часов телефона: серверное время
    ///   и локальное расходятся, и на сдвинутых часах окно чужих изменений
    ///   терялось безвозвратно.
    @discardableResult
    func pull() async throws -> Date? {
        guard let client else { throw SupabaseRESTClient.ClientError.notConfigured }

        let since = lastSyncedAt
        var cursor: Date?

        func advance(_ dates: [Date]) {
            guard let newest = dates.max() else { return }
            cursor = max(cursor ?? newest, newest)
        }

        let people: [PersonDTO] = try await fetchAll(from: "people", since: since, using: client)
        applyPeople(people)
        advance(people.map(\.updatedAt))

        let projects: [ProjectDTO] = try await fetchAll(from: "projects", since: since, using: client)
        applyProjects(projects)
        advance(projects.map(\.updatedAt))

        let captures: [CaptureDTO] = try await fetchAll(from: "captures", since: since, using: client)
        applyCaptures(captures)
        advance(captures.map(\.updatedAt))

        // Указатель на захваты строится один раз за приём. Раньше он
        // собирался заново внутри каждой ветки, то есть пять раз подряд,
        // и каждый раз поднимал таблицу захватов целиком.
        let knownCaptures = captureIndex()

        let notes: [NoteDTO] = try await fetchAll(from: "notes", since: since, using: client)
        applyNotes(notes, captures: knownCaptures)
        advance(notes.map(\.updatedAt))

        let tasks: [TaskDTO] = try await fetchAll(from: "tasks", since: since, using: client)
        applyTasks(tasks, captures: knownCaptures)
        advance(tasks.map(\.updatedAt))

        let reminders: [ReminderDTO] = try await fetchAll(from: "reminders", since: since, using: client)
        applyReminders(reminders, captures: knownCaptures)
        advance(reminders.map(\.updatedAt))

        let expenses: [ExpenseDTO] = try await fetchAll(from: "expenses", since: since, using: client)
        applyExpenses(expenses, captures: knownCaptures)
        advance(expenses.map(\.updatedAt))

        try modelContext.save()
        return cursor
    }

    /// Забирает таблицу целиком, страницами.
    ///
    /// Клиент отдаёт не больше пятисот строк за запрос, а движок брал ровно
    /// одну страницу и после этого двигал отметку времени вперёд. На новом
    /// телефоне это означало, что из трёх тысяч записей приезжали первые
    /// пятьсот, а остальные не приезжали никогда.
    func fetchAll<Payload: SyncPayload>(
        from table: String,
        since: Date?,
        using client: SyncTransport,
        pageSize: Int = 500
    ) async throws -> [Payload] {
        var collected: [Payload] = []
        var cursor = since

        while true {
            let page: [Payload] = try await client.fetchChanges(
                from: table,
                since: cursor,
                limit: pageSize
            )

            collected += page
            guard page.count == pageSize, let last = page.map(\.updatedAt).max() else { break }

            // Следующая страница начинается с последней отметки времени.
            // Если сервер отдал страницу с одинаковым временем во всех
            // строках, сдвинуться некуда, и цикл прерывается.
            guard last != cursor else { break }
            cursor = last
        }

        return collected
    }

    /// Указатель на захват по идентификатору: производные сущности
    /// связываются с ним при создании.
    func captureIndex() -> [UUID: CaptureItem] {
        index(FetchDescriptor<CaptureItem>())
    }

    /// Указатель «идентификатор к записи».
    ///
    /// Дубликат идентификатора больше не роняет приём: раньше здесь стоял
    /// Dictionary(uniqueKeysWithValues:), который на повторяющемся ключе
    /// падает, а сервер вполне может прислать такую пару.
    func index<Model: PersistentModel & Identifiable>(
        _ descriptor: FetchDescriptor<Model>
    ) -> [UUID: Model] where Model.ID == UUID {
        let items = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func applyCaptures(_ dtos: [CaptureDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.capture, id: local.id)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(CaptureItem.make(from: dto))
            }
        }
    }

    func applyNotes(_ dtos: [NoteDTO], captures: [UUID: CaptureItem]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) })
        )
        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.note, id: local.id)
                }
            } else if dto.deletedAt == nil {
                let note = Note.make(from: dto)
                note.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(note)
            }
        }
    }

    func applyTasks(_ dtos: [TaskDTO], captures: [UUID: CaptureItem]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) })
        )
        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.task, id: local.id)
                }
            } else if dto.deletedAt == nil {
                let task = TaskItem.make(from: dto)
                task.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(task)
            }
        }
    }

    func applyReminders(_ dtos: [ReminderDTO], captures: [UUID: CaptureItem]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<Reminder>(predicate: #Predicate { ids.contains($0.id) })
        )
        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.reminder, id: local.id)
                }
            } else if dto.deletedAt == nil {
                let reminder = Reminder.make(from: dto)
                reminder.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(reminder)
            }
        }
    }

    func applyExpenses(_ dtos: [ExpenseDTO], captures: [UUID: CaptureItem]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<Expense>(predicate: #Predicate { ids.contains($0.id) })
        )
        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.expense, id: local.id)
                }
            } else if dto.deletedAt == nil {
                let expense = Expense.make(from: dto)
                expense.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(expense)
            }
        }
    }

    func applyPeople(_ dtos: [PersonDTO]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<Person>(predicate: #Predicate { ids.contains($0.id) })
        )

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.person, id: local.id)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(Person.make(from: dto))
            }
        }
    }

    func applyProjects(_ dtos: [ProjectDTO]) {
        guard !dtos.isEmpty else { return }
        let ids = Set(dtos.map(\.id))
        let existing = index(
            FetchDescriptor<Project>(predicate: #Predicate { ids.contains($0.id) })
        )

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else if !local.apply(dto) {
                    // Серверная копия старше локальной и отброшена. Значит,
                    // наша версия ещё не уехала: без этой строки расхождение
                    // остаётся навсегда, потому что результат применения
                    // раньше просто игнорировался.
                    markChanged(.project, id: local.id)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(Project.make(from: dto))
            }
        }
    }
}
