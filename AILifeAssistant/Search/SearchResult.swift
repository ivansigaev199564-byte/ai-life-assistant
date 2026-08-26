import Foundation

/// Найденная запись.
///
/// Единый тип для всех источников: локальный поиск и серверный отдают
/// одинаковые результаты, и представлению незачем знать, откуда они пришли.
struct SearchResult: Identifiable, Equatable, Sendable {

    enum Kind: String, Sendable {
        case capture, note, task, reminder, expense
    }

    enum Origin: String, Sendable {
        /// Найдено на устройстве: мгновенно, работает офлайн.
        case local
        /// Найдено сервером: понимает смысл, а не только слова.
        case remote
    }

    let id: UUID
    let kind: Kind
    let title: String
    let snippet: String
    let occurredAt: Date
    let origin: Origin
    /// Оценка релевантности. Сравнима только внутри одного источника.
    let score: Double
}

/// Ответ серверной функции поиска.
struct RemoteSearchResponse: Decodable {

    struct Item: Decodable {
        let entityId: UUID
        let entityType: String
        let title: String
        let snippet: String
        let occurredAt: Date
        let score: Double

        enum CodingKeys: String, CodingKey {
            case entityId = "entity_id"
            case entityType = "entity_type"
            case title, snippet, score
            case occurredAt = "occurred_at"
        }
    }

    let results: [Item]
    /// Участвовал ли смысловой поиск. Если нет, сработал только текстовый.
    let semantic: Bool
}
