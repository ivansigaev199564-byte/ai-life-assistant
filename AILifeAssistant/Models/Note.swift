import Foundation
import SwiftData

/// Заметка или идея: то, что не требует действия и не привязано ко времени.
@Model
final class Note {
    @Attribute(.unique) var id: UUID

    var title: String
    var body: String

    /// Свободные метки. Тег "review" ставится, когда уверенность разбора
    /// ниже порога и запись нужно проверить глазами (Этап 5).
    var tags: [String]

    var createdAt: Date
    var updatedAt: Date

    /// Уверенность разбора, 0...1. Для ручного создания равна 1.
    var confidence: Double

    /// Требует проверки пользователем.
    var needsReview: Bool

    var isArchived: Bool

    private var syncStateRaw: String
    var remoteID: String?
    var lastSyncedAt: Date?

    /// Захват, из которого родилась заметка. Обратная связь объявлена
    /// в CaptureItem, здесь только ссылка.
    var source: CaptureItem?

    /// Идентификатор элемента разбора, породившего эту запись.
    /// По нему уточняющий проход находит созданную сущность и обновляет её,
    /// вместо того чтобы создать вторую такую же.
    var parsedItemID: UUID?

    @Relationship(deleteRule: .nullify, inverse: \Person.notes)
    var people: [Person] = []

    @Relationship(deleteRule: .nullify, inverse: \Project.notes)
    var projects: [Project] = []

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String,
        tags: [String] = [],
        confidence: Double = 1,
        needsReview: Bool = false,
        source: CaptureItem? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.confidence = confidence
        self.needsReview = needsReview
        self.isArchived = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.syncStateRaw = SyncState.pendingUpload.rawValue
        self.source = source
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    /// Заголовок для списка: если явного заголовка нет, берём первую строку текста.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? body
        return firstLine.isEmpty ? String(localized: "note.untitled") : firstLine
    }
}
