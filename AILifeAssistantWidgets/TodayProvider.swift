import Foundation
import SwiftData
import WidgetKit

/// Одно дело в виджете.
///
/// Плоская структура вместо модели SwiftData: виджет перерисовывается
/// системой в произвольный момент, и держать в снимке живые объекты базы
/// нельзя, они к тому времени могут стать недействительными.
struct TodayItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let date: Date?
    let isReminder: Bool
    let isOverdue: Bool

    /// Ссылка на само дело: нажатие открывает запись, из которой оно
    /// появилось, а не общий список.
    var deepLink: URL? {
        (isReminder ? DeepLink.reminder(id) : DeepLink.task(id)).url
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let items: [TodayItem]
    /// Сколько всего дел, включая непоместившиеся в виджет.
    let totalCount: Int
}

/// Поставщик данных для виджета «Сегодня».
///
/// Читает базу напрямую через общий контейнер: будить приложение ради
/// перерисовки виджета нельзя, система его просто не запустит.
struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(
            date: .now,
            items: [
                TodayItem(
                    id: UUID(),
                    title: "Позвонить в банк",
                    date: .now.addingTimeInterval(3600),
                    isReminder: true,
                    isOverdue: false
                )
            ],
            totalCount: 1
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = loadEntry()

        // Следующее обновление привязано к ближайшему делу, а не к часу:
        // виджет должен пометить дело просроченным ровно тогда, когда оно
        // просрочено, а не через сорок минут.
        let nextDate = entry.items
            .compactMap(\.date)
            .filter { $0 > .now }
            .min() ?? Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now

        completion(Timeline(entries: [entry], policy: .after(nextDate)))
    }

    // MARK: Чтение базы

    private func loadEntry() -> TodayEntry {
        guard let container = try? Persistence.makeContainer() else {
            return TodayEntry(date: .now, items: [], totalCount: 0)
        }

        let context = ModelContext(container)
        let endOfDay = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59, of: .now
        ) ?? .now

        var items: [TodayItem] = []

        // Условие уходит в базу, а из базы поднимается только то, что нужно
        // показать. Расширение живёт в жёстком лимите памяти около 30 МБ,
        // и подъём всех напоминаний и задач ради шести строк убивал его
        // на второй тысяче записей.
        var reminderDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { !$0.isCompleted && $0.fireDate <= endOfDay },
            sortBy: [SortDescriptor(\.fireDate, order: .forward)]
        )
        reminderDescriptor.fetchLimit = Self.fetchLimit

        items += ((try? context.fetch(reminderDescriptor)) ?? []).map {
            TodayItem(
                id: $0.id,
                title: $0.title,
                date: $0.fireDate,
                isReminder: true,
                isOverdue: $0.fireDate < .now
            )
        }

        // Задачи со сроком на сегодня и раньше, плюс задачи без срока:
        // они всё равно ждут своей очереди и должны попадаться на глаза.
        // Условие только по закрытости: подставить значение вместо nil
        // внутри предиката SwiftData не может, поэтому срок сравнивается
        // уже на поднятых строках. Их немного: лимит и сортировка по сроку
        // ставят ближайшие дела первыми.
        var taskDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.dueDate, order: .forward)]
        )
        taskDescriptor.fetchLimit = Self.fetchLimit

        items += ((try? context.fetch(taskDescriptor)) ?? [])
            .filter { task in
                guard let dueDate = task.dueDate else { return true }
                return dueDate <= endOfDay
            }
            .map {
            TodayItem(
                id: $0.id,
                title: $0.title,
                date: $0.dueDate,
                isReminder: false,
                isOverdue: $0.isOverdue
            )
        }

        // Порядок: сначала просроченное, потом по времени, дела без времени
        // в конце. Так первым в глаза попадает то, что уже горит.
        let sorted = items.sorted { left, right in
            if left.isOverdue != right.isOverdue { return left.isOverdue }
            switch (left.date, right.date) {
            case let (leftDate?, rightDate?): return leftDate < rightDate
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.title < right.title
            }
        }

        // Общее число считаем запросом, а не длиной поднятого массива.
        let total = Self.count(of: reminderDescriptor, in: context)
            + Self.count(of: taskDescriptor, in: context)

        return TodayEntry(
            date: .now,
            items: Array(sorted.prefix(Self.visibleLimit)),
            totalCount: max(total, sorted.count)
        )
    }

    /// Сколько строк поднимать: с запасом на сортировку по просрочке,
    /// но далеко не вся таблица.
    private static let fetchLimit = 24

    /// Сколько дел помещается в самый большой из поддерживаемых виджетов.
    private static let visibleLimit = 6

    private static func count<Model: PersistentModel>(
        of descriptor: FetchDescriptor<Model>,
        in context: ModelContext
    ) -> Int {
        var counting = descriptor
        counting.fetchLimit = 0
        counting.fetchOffset = 0
        return (try? context.fetchCount(counting)) ?? 0
    }
}
