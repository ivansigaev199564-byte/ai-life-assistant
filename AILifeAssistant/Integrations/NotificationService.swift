import Foundation
import Observation
import UserNotifications

/// Локальные уведомления для напоминаний.
///
/// До этого момента приложение исправно создавало напоминания и ни разу
/// о них не напоминало: записи лежали в базе, а система о них не знала.
/// Этот сервис закрывает разрыв между «пользователь сказал напомнить»
/// и «телефон зазвонил».
@MainActor
@Observable
final class NotificationService {

    enum Permission: Equatable, Sendable {
        case notDetermined
        case granted
        case denied
        /// Разрешено, но без звука и баннера: уведомление придёт молча.
        case provisional
    }

    private(set) var permission: Permission = .notDetermined

    private let center = UNUserNotificationCenter.current()

    /// Префикс идентификатора: по нему находятся все уведомления приложения,
    /// когда нужно пересобрать расписание целиком.
    private static let identifierPrefix = "reminder."

    init() {
        Task { await refreshPermission() }
    }

    // MARK: Разрешение

    func refreshPermission() async {
        let settings = await center.notificationSettings()

        permission = switch settings.authorizationStatus {
        case .authorized, .ephemeral: .granted
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Запрашивает разрешение на уведомления.
    ///
    /// Запрашивается не при первом запуске, а в момент создания первого
    /// напоминания: так у системного окна есть понятный повод, и человек
    /// соглашается охотнее, чем на пустом месте.
    @discardableResult
    func requestPermission() async -> Bool {
        guard permission == .notDetermined else { return permission == .granted }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            permission = granted ? .granted : .denied
            return granted
        } catch {
            Log.data.error("Запрос разрешения на уведомления не удался: \(error.localizedDescription)")
            permission = .denied
            return false
        }
    }

    // MARK: Планирование

    /// Ставит уведомление на напоминание.
    ///
    /// Возвращает идентификатор запланированного уведомления: он хранится
    /// в записи, чтобы уведомление можно было отменить при удалении
    /// или перенести при правке времени.
    @discardableResult
    func schedule(for reminder: Reminder) async -> String? {
        guard !reminder.isCompleted else { return nil }

        // Прошедшее время не планируем: система молча отбросит такой запрос,
        // а в базе останется идентификатор несуществующего уведомления.
        // Повторяющееся напоминание исключение: «каждый день в 8:30»,
        // поставленное в десять утра, должно сработать завтра.
        let recurrence = Self.recurringComponents(for: reminder)
        guard recurrence != nil || reminder.fireDate > .now else {
            Log.data.debug("Напоминание в прошлом, уведомление не ставится")
            return nil
        }

        guard await ensurePermission() else { return nil }

        let identifier = Self.identifierPrefix + reminder.id.uuidString

        let content = UNMutableNotificationContent()
        content.title = reminder.title.isEmpty ? "Напоминание" : reminder.title
        if !reminder.details.isEmpty {
            content.body = reminder.details
        }
        content.sound = .default
        // Идентификатор записи едет в уведомлении: по нажатию приложение
        // откроет именно её, а не общий список.
        content.userInfo = ["reminderID": reminder.id.uuidString]

        if reminder.priority == .high {
            content.interruptionLevel = .timeSensitive
        }

        let trigger: UNCalendarNotificationTrigger
        if let recurrence {
            trigger = UNCalendarNotificationTrigger(dateMatching: recurrence, repeats: true)
        } else {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            // Повторная постановка с тем же идентификатором заменяет прежнее
            // уведомление, поэтому отменять его отдельно не нужно.
            try await center.add(request)
            return identifier
        } catch {
            Log.data.error("Уведомление не запланировано: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Повторение

    /// Компоненты повторяющегося срабатывания или nil, если напоминание
    /// разовое.
    ///
    /// Правило приходит строкой из разбора: "daily", "weekly:mon",
    /// "monthly", "weekdays". Последние два вида недельных правил система
    /// одним триггером не выражает, поэтому «по будням» и «по выходным»
    /// пока остаются разовыми, а не превращаются в неверное «каждый день».
    static func recurringComponents(for reminder: Reminder) -> DateComponents? {
        guard let rule = reminder.recurrenceRule, !reminder.isCompleted else { return nil }

        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: reminder.fireDate)

        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute

        let parts = rule.split(separator: ":", maxSplits: 1).map(String.init)

        switch parts.first {
        case "daily":
            return components

        case "weekly":
            components.weekday = parts.count > 1
                ? weekdayNumber(for: parts[1])
                : calendar.component(.weekday, from: reminder.fireDate)
            return components.weekday == nil ? nil : components

        case "monthly":
            components.day = calendar.component(.day, from: reminder.fireDate)
            return components

        default:
            return nil
        }
    }

    /// Номер дня недели в календаре Apple: воскресенье это 1.
    private static func weekdayNumber(for code: String) -> Int? {
        switch code {
        case "sun": return 1
        case "mon": return 2
        case "tue": return 3
        case "wed": return 4
        case "thu": return 5
        case "fri": return 6
        case "sat": return 7
        default: return nil
        }
    }

    /// Отменяет уведомление.
    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func cancel(for reminder: Reminder) {
        let identifier = reminder.notificationIdentifier
            ?? (Self.identifierPrefix + reminder.id.uuidString)
        cancel(identifier: identifier)
    }

    /// Пересобирает расписание по списку напоминаний.
    ///
    /// Нужно после синхронизации: напоминания могли приехать с другого
    /// устройства, и о них система на этом телефоне ничего не знает.
    func rescheduleAll(_ reminders: [Reminder]) async {
        let pending = await center.pendingNotificationRequests()
        let known = Set(pending.map(\.identifier))

        // Повторяющиеся попадают сюда независимо от даты: их «время»
        // осталось в прошлом ровно один раз, а срабатывать они должны и дальше.
        for reminder in reminders
        where !reminder.isCompleted && (reminder.fireDate > .now || reminder.recurrenceRule != nil) {
            let identifier = Self.identifierPrefix + reminder.id.uuidString
            guard !known.contains(identifier) else { continue }

            if let scheduled = await schedule(for: reminder) {
                reminder.notificationIdentifier = scheduled
            }
        }

        // Уведомления удалённых записей снимаем: иначе телефон напомнит
        // о том, чего уже нет.
        let liveIdentifiers = Set(
            reminders.map { Self.identifierPrefix + $0.id.uuidString }
        )
        let orphaned = known
            .filter { $0.hasPrefix(Self.identifierPrefix) }
            .filter { !liveIdentifiers.contains($0) }

        if !orphaned.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(orphaned))
            Log.data.debug("Снято устаревших уведомлений: \(orphaned.count)")
        }
    }

    private func ensurePermission() async -> Bool {
        if permission == .notDetermined {
            return await requestPermission()
        }
        return permission == .granted || permission == .provisional
    }
}
