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

    /// Что уходит в файл. Снимок отделён от кодирования, чтобы кодировать
    /// можно было вне главного актора.
    enum Payload: Sendable {
        case json(ExportSnapshot)
        case csv(rows: [[String]], header: String)

        func encoded() throws -> Data {
            switch self {
            case .json(let snapshot):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(snapshot)

            case .csv(let rows, let header):
                var lines = [header]
                lines += rows.map { $0.map(ExportService.escape).joined(separator: ",") }

                // Метка кодировки в начале файла: без неё Excel открывает
                // кириллицу кракозябрами, и выгрузка выглядит испорченной,
                // хотя данные целы.
                var data = Data([0xEF, 0xBB, 0xBF])
                data.append(lines.joined(separator: "\n").data(using: .utf8) ?? Data())
                return data
            }
        }
    }

    /// Готовит файл выгрузки и возвращает путь к нему.
    ///
    /// Модели SwiftData живут на главном акторе, поэтому снимок собирается
    /// здесь. Кодирование и запись уходят с главного потока: на тысячах
    /// записей они держали интерфейс несколько секунд прямо в обработчике
    /// нажатия кнопки.
    func export(_ format: Format) async throws -> URL {
        let payload: Payload = switch format {
        case .json: .json(makeSnapshot())
        case .csv: .csv(rows: makeCSVRows(), header: String(localized: "export.csv.header"))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let name = "ai-assistant-" + formatter.string(from: .now) + "." + format.fileExtension
        let directory = try Self.exportDirectory()
        let url = directory.appendingPathComponent(name)

        // Прошлые выгрузки уходят: полный дамп дневника не должен лежать
        // на диске неопределённо долго только потому, что человек однажды
        // открыл лист «Поделиться» и передумал.
        Self.removePreviousExports(in: directory, keeping: name)

        try await Task.detached(priority: .userInitiated) {
            // Файл с полным содержимым дневника пишется с максимальной
            // защитой: он не нужен приложению при заблокированном экране.
            try payload.encoded().write(to: url, options: [.atomic, .completeFileProtection])
        }.value

        return url
    }

    /// Отдельный каталог для выгрузок вместо общей временной папки.
    ///
    /// Система чистит tmp только под давлением на диск, поэтому дамп мог
    /// лежать там неделями, доступный всему, что имеет доступ к контейнеру.
    static func exportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("Exports", isDirectory: true)

        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var mutable = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }

        return folder
    }

    /// Удаляет прежние выгрузки.
    static func removePreviousExports(in directory: URL, keeping name: String? = nil) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in contents where url.lastPathComponent != name {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Чистка при запуске: файл, который человек так и не отправил,
    /// не должен пережить перезапуск приложения.
    static func removeStaleExports() {
        guard let directory = try? exportDirectory() else { return }
        removePreviousExports(in: directory)
    }

    private func fetch<Model: PersistentModel>(_ type: Model.Type) -> [Model] {
        (try? modelContext.fetch(FetchDescriptor<Model>())) ?? []
    }
}

// MARK: - Форматы

private extension ExportService {

    func makeSnapshot() -> ExportSnapshot {
        ExportSnapshot(
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
    }

    /// Строки CSV собираются на главном акторе: локализованное название
    /// категории берётся из модели, а склейка уходит на фон.
    func makeCSVRows() -> [[String]] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return fetch(Expense.self)
            .sorted { $0.spentAt > $1.spentAt }
            .map { expense in
                [
                    formatter.string(from: expense.spentAt),
                    NSDecimalNumber(decimal: expense.amount).stringValue,
                    expense.currencyCode,
                    expense.category.displayName,
                    expense.details,
                    expense.merchant ?? ""
                ]
            }
    }

    /// Экранирование поля: описание траты вполне может содержать запятую.
    static func escape(_ field: String) -> String {
        var value = field

        // Поле, начинающееся со знака равенства, плюса, минуса или собачки,
        // Excel исполняет как формулу при открытии файла. Текст в выгрузке
        // приходит из распознавания речи, то есть снаружи, поэтому такие
        // поля обезвреживаются апострофом.
        if let first = value.first, "=+-@".contains(first) || first == "\t" || first == "\r" {
            value = "'" + value
        }

        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
