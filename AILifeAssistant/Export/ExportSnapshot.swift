import Foundation

/// Структура файла выгрузки.
///
/// Отдельные типы, а не модели SwiftData: файл переживёт и приложение,
/// и схему базы, поэтому обязан читаться без них.
struct ExportSnapshot: Encodable {

    struct Capture: Encodable {
        let id: UUID
        let text: String
        let source: String
        let status: String
        let language: String?
        let createdAt: Date
        let parsedAt: Date?
        let parseConfidence: Double
    }

    struct Note: Encodable {
        let id: UUID
        let captureId: UUID?
        let title: String
        let body: String
        let tags: [String]
        let createdAt: Date
    }

    struct Task: Encodable {
        let id: UUID
        let captureId: UUID?
        let title: String
        let details: String
        let dueDate: Date?
        let priority: String
        let isCompleted: Bool
        let createdAt: Date
    }

    struct Reminder: Encodable {
        let id: UUID
        let captureId: UUID?
        let title: String
        let details: String
        let fireDate: Date
        let priority: String
        let isCompleted: Bool
        let createdAt: Date
    }

    struct Expense: Encodable {
        let id: UUID
        let captureId: UUID?
        /// Сумма строкой: числа с плавающей точкой в JSON округляются,
        /// и копейки теряются при переносе.
        let amount: String
        let currency: String
        let category: String
        let details: String
        let merchant: String?
        let spentAt: Date
    }

    struct Person: Encodable {
        let id: UUID
        let name: String
        let aliases: [String]
        let mentions: Int
    }

    struct Project: Encodable {
        let id: UUID
        let name: String
        let aliases: [String]
        let isArchived: Bool
    }

    let exportedAt: Date
    let appVersion: String
    let captures: [Capture]
    let notes: [Note]
    let tasks: [Task]
    let reminders: [Reminder]
    let expenses: [Expense]
    let people: [Person]
    let projects: [Project]
}
