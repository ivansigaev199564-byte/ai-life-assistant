import EventKit
import Foundation
import Observation

/// Доступ к системным Напоминаниям и Календарю.
///
/// Смысл интеграции не в дублировании данных, а в том, чтобы сказанное
/// голосом оказалось там, куда человек и так смотрит. Напоминание из фразы
/// «напомни завтра позвонить в банк» должно всплыть на часах и в машине,
/// а не только внутри этого приложения.
@MainActor
@Observable
final class EventKitService {

    enum Access: Equatable, Sendable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    private(set) var remindersAccess: Access = .notDetermined
    private(set) var calendarAccess: Access = .notDetermined

    private let store = EKEventStore()

    /// Название списка, в котором приложение держит свои напоминания.
    /// Отдельный список, а не системный по умолчанию: пользователь видит,
    /// что пришло из приложения, и может отключить это одним движением.
    static let listTitle = "AI Assistant"

    init() {
        refreshAccess()
    }

    // MARK: Разрешения

    func refreshAccess() {
        remindersAccess = Self.map(EKEventStore.authorizationStatus(for: .reminder))
        calendarAccess = Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    /// Запрашивает полный доступ к напоминаниям.
    ///
    /// Именно полный: доступ только на запись позволил бы создавать записи,
    /// но не проверять, не выполнил ли их пользователь в системном
    /// приложении, а без этого зеркалирование теряет смысл.
    @discardableResult
    func requestRemindersAccess() async -> Bool {
        guard remindersAccess == .notDetermined else { return remindersAccess == .granted }

        do {
            let granted = try await store.requestFullAccessToReminders()
            remindersAccess = granted ? .granted : .denied
            return granted
        } catch {
            Log.data.error("Доступ к напоминаниям не получен: \(error.localizedDescription)")
            remindersAccess = .denied
            return false
        }
    }

    @discardableResult
    func requestCalendarAccess() async -> Bool {
        guard calendarAccess == .notDetermined else { return calendarAccess == .granted }

        do {
            let granted = try await store.requestFullAccessToEvents()
            calendarAccess = granted ? .granted : .denied
            return granted
        } catch {
            Log.data.error("Доступ к календарю не получен: \(error.localizedDescription)")
            calendarAccess = .denied
            return false
        }
    }

    // MARK: Список приложения

    /// Находит или создаёт список напоминаний приложения.
    func appReminderList() -> EKCalendar? {
        guard remindersAccess == .granted else { return nil }

        if let existing = store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle }) {
            return existing
        }

        // Создавать список можно не в каждом источнике: локальный и iCloud
        // подходят, подписки и общие календари нет.
        guard let source = preferredSource() else {
            Log.data.notice("Нет источника, в котором можно создать список напоминаний")
            return nil
        }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.listTitle
        calendar.source = source

        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            Log.data.error("Список напоминаний не создан: \(error.localizedDescription)")
            return nil
        }
    }

    /// Источник для нового списка: сначала iCloud, чтобы напоминания
    /// разошлись по устройствам, затем локальный.
    private func preferredSource() -> EKSource? {
        let sources = store.sources

        if let cloud = sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" }) {
            return cloud
        }
        if let local = sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.defaultCalendarForNewReminders()?.source
    }

    // MARK: Напоминания

    /// Создаёт или обновляет системное напоминание.
    /// - Returns: идентификатор системной записи.
    @discardableResult
    func mirror(_ reminder: Reminder) async -> String? {
        let hasAccess = remindersAccess == .granted || await requestRemindersAccess()
        guard hasAccess, let list = appReminderList() else { return nil }

        let systemReminder: EKReminder

        if let identifier = reminder.externalIdentifier,
           let existing = store.calendarItem(withIdentifier: identifier) as? EKReminder {
            systemReminder = existing
        } else {
            systemReminder = EKReminder(eventStore: store)
            systemReminder.calendar = list
        }

        systemReminder.title = reminder.title
        systemReminder.notes = reminder.details.isEmpty ? nil : reminder.details
        systemReminder.priority = reminder.priority.ekPriority
        systemReminder.isCompleted = reminder.isCompleted

        systemReminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.fireDate
        )

        // Собственная тревога системного напоминания: без неё запись просто
        // лежит в списке и ни о чём не сигналит.
        if !reminder.isCompleted, reminder.fireDate > .now {
            systemReminder.alarms?.forEach { systemReminder.removeAlarm($0) }
            systemReminder.addAlarm(EKAlarm(absoluteDate: reminder.fireDate))
        }

        do {
            try store.save(systemReminder, commit: true)
            return systemReminder.calendarItemIdentifier
        } catch {
            Log.data.error("Системное напоминание не сохранено: \(error.localizedDescription)")
            return nil
        }
    }

    /// Удаляет системное напоминание.
    func removeMirror(identifier: String) {
        guard remindersAccess == .granted else { return }
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }

        do {
            try store.remove(item, commit: true)
        } catch {
            Log.data.error("Системное напоминание не удалено: \(error.localizedDescription)")
        }
    }

    /// Проверяет, какие напоминания пользователь закрыл в системном приложении.
    ///
    /// Без этой проверки получалась бы неприятная вещь: человек отметил дело
    /// выполненным в Напоминаниях, а здесь оно продолжает висеть открытым.
    func fetchCompletedIdentifiers(among identifiers: [String]) -> Set<String> {
        guard remindersAccess == .granted, !identifiers.isEmpty else { return [] }

        let items = identifiers.compactMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
        return Set(items.filter(\.isCompleted).map(\.calendarItemIdentifier))
    }

    // MARK: Календарь

    /// Создаёт событие календаря.
    ///
    /// Встречи и созвоны уместнее в календаре, чем в списке дел: они
    /// занимают время, а не просто ждут своей очереди.
    @discardableResult
    func createEvent(
        title: String,
        startDate: Date,
        duration: TimeInterval = 3600,
        notes: String? = nil
    ) async -> String? {
        let hasAccess = calendarAccess == .granted || await requestCalendarAccess()
        guard hasAccess, let calendar = store.defaultCalendarForNewEvents else { return nil }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(duration)
        event.notes = notes
        event.calendar = calendar
        // Напоминание за пятнадцать минут: столько обычно нужно,
        // чтобы дойти или переключиться.
        event.addAlarm(EKAlarm(relativeOffset: -900))

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            Log.data.error("Событие календаря не создано: \(error.localizedDescription)")
            return nil
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess, .writeOnly: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}
