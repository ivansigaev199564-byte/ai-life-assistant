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
    private let sessionProvider: () -> String?

    /// Ключ отметки последней синхронизации.
    private static let lastSyncKey = "sync.lastSyncedAt"

    init(
        modelContext: ModelContext,
        queue: SyncQueue,
        networkMonitor: NetworkMonitor,
        sessionProvider: @escaping () -> String?
    ) {
        self.modelContext = modelContext
        self.queue = queue
        self.networkMonitor = networkMonitor
        self.sessionProvider = sessionProvider
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
        SupabaseConfiguration.isConfigured && sessionProvider() != nil
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
            try await pull()

            lastSyncedAt = .now
            UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncKey)
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
}

// MARK: - Отправка

private extension SyncEngine {

    var client: SupabaseRESTClient? {
        guard let configuration = SupabaseConfiguration.current else { return nil }
        return SupabaseRESTClient(configuration: configuration, accessToken: sessionProvider())
    }

    /// Отправляет локальные изменения пачками по типам сущностей.
    ///
    /// Пачками, а не по одной записи: сотня отдельных запросов на первой
    /// синхронизации после установки съест и трафик, и лимиты сервера.
    func push() async throws {
        guard let client else { throw SupabaseRESTClient.ClientError.notConfigured }

        let operations = queue.next(limit: 200)
        guard !operations.isEmpty else { return }

        let grouped = Dictionary(grouping: operations, by: \.entityType)

        for (entityType, typeOperations) in grouped {
            let upserts = typeOperations.filter { $0.kind == .upsert }
            guard !upserts.isEmpty else { continue }

            let ids = Set(upserts.map(\.entityID))

            do {
                try await pushEntities(of: entityType, ids: ids, using: client)
                upserts.forEach(queue.complete)
            } catch {
                // Записи остаются в очереди и уедут при следующей попытке:
                // ошибка сети не должна терять данные.
                upserts.forEach(queue.fail)
                throw error
            }
        }

        pendingCount = queue.pendingCount
    }

    /// Собирает записи нужного типа и отправляет их на сервер.
    func pushEntities(
        of entityType: SyncEntityType,
        ids: Set<UUID>,
        using client: SupabaseRESTClient
    ) async throws {
        switch entityType {
        case .capture:
            let items = try fetchLocal(CaptureItem.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            markSynced(items)

        case .note:
            let items = try fetchLocal(Note.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .task:
            let items = try fetchLocal(TaskItem.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .reminder:
            let items = try fetchLocal(Reminder.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .expense:
            let items = try fetchLocal(Expense.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .person:
            let items = try fetchLocal(Person.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
            items.forEach { $0.syncState = .synced }

        case .project:
            let items = try fetchLocal(Project.self).filter { ids.contains($0.id) }
            try await client.upsert(items.map(\.dto), into: entityType.tableName)
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

    func fetchLocal<Model: PersistentModel>(_ type: Model.Type) throws -> [Model] {
        try modelContext.fetch(FetchDescriptor<Model>())
    }
}

// MARK: - Получение

private extension SyncEngine {

    /// Забирает всё, что изменилось на сервере после прошлой синхронизации.
    ///
    /// Порядок типов не случаен: люди и проекты идут первыми, затем захваты,
    /// и только потом производные сущности. Иначе заметка приедет раньше
    /// захвата, из которого сделана, и связь окажется пустой.
    func pull() async throws {
        guard let client else { throw SupabaseRESTClient.ClientError.notConfigured }

        let since = lastSyncedAt

        let people: [PersonDTO] = try await client.fetchChanges(from: "people", since: since)
        applyPeople(people)

        let projects: [ProjectDTO] = try await client.fetchChanges(from: "projects", since: since)
        applyProjects(projects)

        let captures: [CaptureDTO] = try await client.fetchChanges(from: "captures", since: since)
        applyCaptures(captures)

        let notes: [NoteDTO] = try await client.fetchChanges(from: "notes", since: since)
        applyNotes(notes)

        let tasks: [TaskDTO] = try await client.fetchChanges(from: "tasks", since: since)
        applyTasks(tasks)

        let reminders: [ReminderDTO] = try await client.fetchChanges(from: "reminders", since: since)
        applyReminders(reminders)

        let expenses: [ExpenseDTO] = try await client.fetchChanges(from: "expenses", since: since)
        applyExpenses(expenses)

        try modelContext.save()
    }

    /// Указатель на захват по идентификатору: производные сущности
    /// связываются с ним при создании.
    func captureIndex() -> [UUID: CaptureItem] {
        let items = (try? fetchLocal(CaptureItem.self)) ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    func applyCaptures(_ dtos: [CaptureDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(CaptureItem.make(from: dto))
            }
        }
    }

    func applyNotes(_ dtos: [NoteDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(Note.self)) ?? []).map { ($0.id, $0) }
        )
        let captures = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                let note = Note.make(from: dto)
                note.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(note)
            }
        }
    }

    func applyTasks(_ dtos: [TaskDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(TaskItem.self)) ?? []).map { ($0.id, $0) }
        )
        let captures = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                let task = TaskItem.make(from: dto)
                task.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(task)
            }
        }
    }

    func applyReminders(_ dtos: [ReminderDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(Reminder.self)) ?? []).map { ($0.id, $0) }
        )
        let captures = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                let reminder = Reminder.make(from: dto)
                reminder.source = dto.captureId.flatMap { captures[$0] }
                modelContext.insert(reminder)
            }
        }
    }

    func applyExpenses(_ dtos: [ExpenseDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(Expense.self)) ?? []).map { ($0.id, $0) }
        )
        let captures = captureIndex()

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
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
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(Person.self)) ?? []).map { ($0.id, $0) }
        )

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(Person.make(from: dto))
            }
        }
    }

    func applyProjects(_ dtos: [ProjectDTO]) {
        guard !dtos.isEmpty else { return }
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? fetchLocal(Project.self)) ?? []).map { ($0.id, $0) }
        )

        for dto in dtos {
            if let local = existing[dto.id] {
                if dto.deletedAt != nil {
                    modelContext.delete(local)
                } else {
                    local.apply(dto)
                }
            } else if dto.deletedAt == nil {
                modelContext.insert(Project.make(from: dto))
            }
        }
    }
}
