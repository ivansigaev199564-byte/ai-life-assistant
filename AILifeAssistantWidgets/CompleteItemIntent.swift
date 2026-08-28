import AppIntents
import SwiftData
import WidgetKit

/// Отметка «выполнено» прямо из виджета, без открытия приложения.
///
/// Смысл виджета в том, чтобы не заходить внутрь. Если ради галочки всё
/// равно приходится открывать приложение, виджет остаётся картинкой.
///
/// Интент пишет в общую базу напрямую: будить приложение ради одной отметки
/// система не станет. Локальное уведомление при этом остаётся в расписании,
/// снять чужое расширение не может, поэтому его убирает приложение при
/// следующем запуске, когда пересобирает расписание.
struct CompleteItemIntent: AppIntent {

    static var title: LocalizedStringResource = "Отметить выполненным"

    /// В Ярлыках интент не нужен: он служебный и работает по идентификатору,
    /// который человеку взять неоткуда.
    static var isDiscoverable: Bool = false

    @Parameter(title: "Идентификатор")
    var itemID: String

    @Parameter(title: "Это напоминание")
    var isReminder: Bool

    init() {}

    init(itemID: UUID, isReminder: Bool) {
        self.itemID = itemID.uuidString
        self.isReminder = isReminder
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: itemID) else { return .result() }

        guard let container = try? Persistence.makeContainer() else {
            Log.data.error("Виджет не смог открыть хранилище для отметки")
            return .result()
        }

        let context = ModelContext(container)

        if isReminder {
            var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let reminder = try? context.fetch(descriptor).first else { return .result() }
            reminder.setCompleted(true)
        } else {
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let task = try? context.fetch(descriptor).first else { return .result() }
            task.setCompleted(true)
        }

        do {
            try context.save()
        } catch {
            Log.data.error("Отметка из виджета не сохранена: \(error.localizedDescription)")
            return .result()
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
