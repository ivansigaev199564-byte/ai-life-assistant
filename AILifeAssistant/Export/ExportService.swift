import Foundation
import SwiftData

/// Выгрузка данных из приложения.
///
/// Приложение обещает, что записи принадлежат человеку. Обещание пустое,
/// пока их нельзя забрать: данные, которые невозможно вынести, принадлежат
/// приложению, а не пользователю.
///
/// Форматов два, потому что задачи разные. JSON сохраняет всё до последнего
/// поля и годится для переноса или архива. CSV открывается в любой таблице
/// и нужен тому, кто хочет посчитать свои траты сам.
@MainActor
struct ExportService {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case json
        case csv

        var id: String { rawValue }

        var title: String {
            switch self {
            case .json: return "JSON, всё целиком"
            case .csv: return "CSV, только траты"
            }
        }

        var fileExtension: String { rawValue }
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Готовит файл выгрузки и возвращает путь к нему.
    func export(_ format: Format) throws -> URL {
        let data: Data

        switch format {
        case .json: data = try makeJSON()
        case .csv: data = try makeCSV()
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let name = "ai-assistant-" + formatter.string(from: .now) + "." + format.fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        try data.write(to: url, options: .atomic)
        return url
    }

    private func fetch<Model: PersistentModel>(_ type: Model.Type) -> [Model] {
        (try? modelContext.fetch(FetchDescriptor<Model>())) ?? []
    }
}

// MARK: - Форматы

private extension ExportService {

    func makeJSON() throws -> Data {
        let snapshot = ExportSnapshot(
            exportedAt: .now,
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            captures: fetch(CaptureItem.self).map {
                ExportSnapshot.Capture(
                    id: $0.id,
                    text: $0.text,
                    source: $0.source.rawValue,
                    status: $0.status.rawValue,
                    language: $0.languageCode,
                    createdAt: $0.createdAt,
                    parsedAt: $0.parsedAt,
                    parseConfidence: $0.parseConfidence
                )
            },
            notes: fetch(Note.self).map {
                ExportSnapshot.Note(
                    id: $0.id,
                    captureId: $0.source?.id,
                    title: $0.title,
                    body: $0.body,
                    tags: $0.tags,
                    createdAt: $0.createdAt
                )
            },
            tasks: fetch(TaskItem.self).map {
                ExportSnapshot.Task(
                    id: $0.id,
                    captureId: $0.source?.id,
                    title: $0.title,
                    details: $0.details,
                    dueDate: $0.dueDate,
                    priority: $0.priority.rawValue,
                    isCompleted: $0.isCompleted,
                    createdAt: $0.createdAt
                )
            },
            reminders: fetch(Reminder.self).map {
                ExportSnapshot.Reminder(
                    id: $0.id,
                    captureId: $0.source?.id,
                    title: $0.title,
                    details: $0.details,
                    fireDate: $0.fireDate,
                    priority: $0.priority.rawValue,
                    isCompleted: $0.isCompleted,
                    createdAt: $0.createdAt
                )
            },
            expenses: fetch(Expense.self).map {
                ExportSnapshot.Expense(
                    id: $0.id,
                    captureId: $0.source?.id,
                    amount: NSDecimalNumber(decimal: $0.amount).stringValue,
                    currency: $0.currencyCode,
                    category: $0.category.rawValue,
                    details: $0.details,
                    merchant: $0.merchant,
                    spentAt: $0.spentAt
                )
            },
            people: fetch(Person.self).map {
                ExportSnapshot.Person(
                    id: $0.id,
                    name: $0.name,
                    aliases: $0.aliases,
                    mentions: $0.totalMentions
                )
            },
            projects: fetch(Project.self).map {
                ExportSnapshot.Project(
                    id: $0.id,
                    name: $0.name,
                    aliases: $0.aliases,
                    isArchived: $0.isArchived
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    func makeCSV() throws -> Data {
        var rows = [String(localized: "export.csv.header")]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        for expense in fetch(Expense.self).sorted(by: { $0.spentAt > $1.spentAt }) {
            let fields = [
                formatter.string(from: expense.spentAt),
                NSDecimalNumber(decimal: expense.amount).stringValue,
                expense.currencyCode,
                expense.category.displayName,
                expense.details,
                expense.merchant ?? ""
            ]
            rows.append(fields.map(Self.escape).joined(separator: ","))
        }

        // Метка кодировки в начале файла: без неё Excel открывает кириллицу
        // кракозябрами, и выгрузка выглядит испорченной, хотя данные целы.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(rows.joined(separator: "\n").data(using: .utf8) ?? Data())
        return data
    }

    /// Экранирование поля: описание траты вполне может содержать запятую.
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
