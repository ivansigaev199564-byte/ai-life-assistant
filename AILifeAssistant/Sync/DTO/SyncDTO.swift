import Foundation

/// Серверные представления сущностей.
///
/// Отдельные типы, а не прямая сериализация моделей SwiftData: у сервера
/// свои поля (владелец, версия, мягкое удаление) и своя запись имён через
/// подчёркивание. Смешивать это с моделями значит однажды отправить
/// на сервер лишнее или потерять нужное.

/// Общая часть всех записей на сервере.
protocol SyncPayload: Codable, Sendable {
    var id: UUID { get }
    var updatedAt: Date { get }
    var version: Int64 { get }
    var deletedAt: Date? { get }
}

struct CaptureDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var text: String
    var source: String
    var status: String
    var engine: String
    var languageCode: String?
    var recognitionConfidence: Double
    var parseConfidence: Double
    var parsingEngine: String?
    var audioDuration: Double
    var createdAt: Date
    var updatedAt: Date
    var parsedAt: Date?
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case text, source, status, engine, version
        case languageCode = "language_code"
        case recognitionConfidence = "recognition_confidence"
        case parseConfidence = "parse_confidence"
        case parsingEngine = "parsing_engine"
        case audioDuration = "audio_duration"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case parsedAt = "parsed_at"
        case deletedAt = "deleted_at"
    }
}

struct NoteDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var captureId: UUID?
    var parsedItemId: UUID?
    var title: String
    var body: String
    var tags: [String]
    var confidence: Double
    var needsReview: Bool
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, body, tags, confidence, version
        case userId = "user_id"
        case captureId = "capture_id"
        case parsedItemId = "parsed_item_id"
        case needsReview = "needs_review"
        case isArchived = "is_archived"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct TaskDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var captureId: UUID?
    var parsedItemId: UUID?
    var title: String
    var details: String
    var dueDate: Date?
    var priority: String
    var isCompleted: Bool
    var completedAt: Date?
    var externalReminderId: String?
    var confidence: Double
    var needsReview: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, details, priority, confidence, version
        case userId = "user_id"
        case captureId = "capture_id"
        case parsedItemId = "parsed_item_id"
        case dueDate = "due_date"
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case externalReminderId = "external_reminder_id"
        case needsReview = "needs_review"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ReminderDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var captureId: UUID?
    var parsedItemId: UUID?
    var title: String
    var details: String
    var fireDate: Date
    var recurrenceRule: String?
    var priority: String
    var isCompleted: Bool
    var completedAt: Date?
    var externalIdentifier: String?
    var confidence: Double
    var needsReview: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, details, priority, confidence, version
        case userId = "user_id"
        case captureId = "capture_id"
        case parsedItemId = "parsed_item_id"
        case fireDate = "fire_date"
        case recurrenceRule = "recurrence_rule"
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case externalIdentifier = "external_identifier"
        case needsReview = "needs_review"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ExpenseDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var captureId: UUID?
    var parsedItemId: UUID?
    /// Сумма передаётся строкой: у сервера это numeric, и перевод через
    /// число с плавающей точкой потерял бы копейки.
    var amount: String
    var currencyCode: String
    var category: String
    var details: String
    var merchant: String?
    var spentAt: Date
    var confidence: Double
    var needsReview: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, amount, category, details, merchant, confidence, version
        case userId = "user_id"
        case captureId = "capture_id"
        case parsedItemId = "parsed_item_id"
        case currencyCode = "currency_code"
        case spentAt = "spent_at"
        case needsReview = "needs_review"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct PersonDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var name: String
    var normalizedName: String
    var aliases: [String]
    var contactIdentifier: String?
    var mentionCount: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, version
        case userId = "user_id"
        case normalizedName = "normalized_name"
        case contactIdentifier = "contact_identifier"
        case mentionCount = "mention_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ProjectDTO: SyncPayload {
    let id: UUID
    var userId: UUID?
    var name: String
    var normalizedName: String
    var aliases: [String]
    var details: String
    var colorHex: String
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, details, version
        case userId = "user_id"
        case normalizedName = "normalized_name"
        case colorHex = "color_hex"
        case isArchived = "is_archived"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
