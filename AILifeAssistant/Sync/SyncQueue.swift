import Foundation
import Observation

/// Тип сущности в очереди синхронизации.
enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case capture, note, task, reminder, expense, person, project

    /// Имя таблицы на сервере.
    var tableName: String {
        switch self {
        case .capture: return "captures"
        case .note: return "notes"
        case .task: return "tasks"
        case .reminder: return "reminders"
        case .expense: return "expenses"
        case .person: return "people"
        case .project: return "projects"
        }
    }
}

/// Одна отложенная операция.
struct SyncOperation: Codable, Identifiable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        case upsert
        case delete
    }

    let id: UUID
    let entityType: SyncEntityType
    let entityID: UUID
    let kind: Kind
    let queuedAt: Date
    var attempts: Int

    init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: UUID,
        kind: Kind,
        queuedAt: Date = .now,
        attempts: Int = 0
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.kind = kind
        self.queuedAt = queuedAt
        self.attempts = attempts
    }
}

/// Очередь операций синхронизации, переживающая перезапуск приложения.
///
/// Хранится файлом, а не в базе: очередь это служебное состояние, которому
/// нечего делать в пользовательских данных, и её потеря не должна стоить
/// миграции схемы.
@MainActor
@Observable
final class SyncQueue {

    /// Сколько раз пробовать отправить операцию, прежде чем отложить её.
    static let maxAttempts = 5

    private(set) var operations: [SyncOperation] = []

    private let fileURL: URL?

    init(fileName: String = "sync-queue.json") {
        self.fileURL = Self.makeFileURL(fileName: fileName)
        load()
    }

    var pendingCount: Int { operations.count }

    // MARK: Операции

    /// Ставит операцию в очередь.
    ///
    /// Повторная постановка той же сущности заменяет предыдущую: отправлять
    /// одну запись дважды бессмысленно, на сервер уедет её текущее состояние.
    func enqueue(_ entityType: SyncEntityType, id entityID: UUID, kind: SyncOperation.Kind) {
        operations.removeAll { $0.entityType == entityType && $0.entityID == entityID }
        operations.append(SyncOperation(entityType: entityType, entityID: entityID, kind: kind))
        persist()
    }

    /// Ближайшие операции к отправке.
    func next(limit: Int = 50) -> [SyncOperation] {
        operations
            .filter { $0.attempts < Self.maxAttempts }
            .sorted { $0.queuedAt < $1.queuedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Операция выполнена, убираем из очереди.
    func complete(_ operation: SyncOperation) {
        operations.removeAll { $0.id == operation.id }
        persist()
    }

    /// Операция не удалась: увеличиваем счётчик попыток.
    func fail(_ operation: SyncOperation) {
        guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { return }
        operations[index].attempts += 1

        if operations[index].attempts >= Self.maxAttempts {
            Log.data.error("""
                Операция синхронизации исчерпала попытки: \
                \(operation.entityType.rawValue, privacy: .public) \
                \(operation.entityID.uuidString, privacy: .public)
                """)
        }
        persist()
    }

    /// Сброс счётчиков: вызывается, когда связь появилась после перерыва.
    /// Прошлые неудачи были вызваны отсутствием сети, а не данными.
    func resetAttempts() {
        guard operations.contains(where: { $0.attempts > 0 }) else { return }
        for index in operations.indices {
            operations[index].attempts = 0
        }
        persist()
    }

    func clear() {
        operations.removeAll()
        persist()
    }

    // MARK: Хранение

    private static func makeFileURL(fileName: String) -> URL? {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return directory.appendingPathComponent(fileName)
        } catch {
            Log.data.error("Каталог для очереди недоступен: \(error.localizedDescription)")
            return nil
        }
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            operations = try decoder.decode([SyncOperation].self, from: data)
        } catch {
            // Битую очередь лучше потерять, чем не запуститься: сами данные
            // лежат в базе, и при следующем изменении операции встанут заново.
            Log.data.error("Очередь синхронизации не прочиталась: \(error.localizedDescription)")
            operations = []
        }
    }

    private func persist() {
        guard let fileURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(operations)
            // Атомарная запись: обрыв на середине не оставит битый файл.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.data.error("Очередь синхронизации не сохранилась: \(error.localizedDescription)")
        }
    }
}
