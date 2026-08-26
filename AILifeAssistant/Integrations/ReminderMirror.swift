import Foundation
import Observation
import SwiftData

/// Связывает напоминания приложения с системой.
///
/// Отвечает за две вещи, которые пользователь воспринимает как одну:
/// телефон должен зазвонить в нужный момент, и запись должна появиться
/// в системных Напоминаниях, где человек её увидит на часах и в машине.
///
/// Синхронизация двусторонняя: дело, закрытое в системном приложении,
/// закрывается и здесь. Иначе список дел начинает врать, а это худшее,
/// что может случиться со списком дел.
@MainActor
@Observable
final class ReminderMirror {

    private(set) var isMirroringEnabled: Bool
    private(set) var lastSyncAt: Date?

    private let modelContext: ModelContext
    private let notifications: NotificationService
    private let eventKit: EventKitService

    private static let mirroringKey = "integrations.mirrorToReminders"

    init(
        modelContext: ModelContext,
        notifications: NotificationService,
        eventKit: EventKitService,
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.notifications = notifications
        self.eventKit = eventKit
        // По умолчанию выключено: заливать чужие записи в системные
        // Напоминания без спроса невежливо.
        self.isMirroringEnabled = defaults.object(forKey: Self.mirroringKey) as? Bool ?? false
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    func setMirroring(_ enabled: Bool) {
        isMirroringEnabled = enabled
        defaults.set(enabled, forKey: Self.mirroringKey)

        Task {
            if enabled {
                await mirrorAll()
            } else {
                await removeAllMirrors()
            }
        }
    }

    // MARK: Одна запись

    /// Ставит уведомление и, если включено, зеркалит в системные Напоминания.
    func register(_ reminder: Reminder) async {
        if let identifier = await notifications.schedule(for: reminder) {
            reminder.notificationIdentifier = identifier
        }

        if isMirroringEnabled, let externalID = await eventKit.mirror(reminder) {
            reminder.externalIdentifier = externalID
        }

        save()
    }

    /// Обновляет уведомление и системную копию после правки.
    func update(_ reminder: Reminder) async {
        notifications.cancel(for: reminder)

        guard !reminder.isCompleted else {
            reminder.notificationIdentifier = nil
            if let externalID = reminder.externalIdentifier {
                // Выполненное напоминание не удаляем из системы, а помечаем
                // выполненным: пользователь увидит, что дело закрыто, а не
                // что оно бесследно исчезло.
                _ = await eventKit.mirror(reminder)
                _ = externalID
            }
            save()
            return
        }

        await register(reminder)
    }

    /// Снимает уведомление и системную копию.
    func unregister(_ reminder: Reminder) {
        notifications.cancel(for: reminder)

        if let externalID = reminder.externalIdentifier {
            eventKit.removeMirror(identifier: externalID)
        }
    }

    // MARK: Все записи

    /// Пересобирает расписание уведомлений.
    ///
    /// Нужно после запуска и после синхронизации: напоминания могли приехать
    /// с другого устройства, и система на этом телефоне о них не знает.
    func refreshSchedule() async {
        let reminders = fetchActiveReminders()
        await notifications.rescheduleAll(reminders)
        save()
    }

    /// Заливает все активные напоминания в системный список.
    func mirrorAll() async {
        guard isMirroringEnabled else { return }

        for reminder in fetchActiveReminders() {
            if let externalID = await eventKit.mirror(reminder) {
                reminder.externalIdentifier = externalID
            }
        }
        save()
    }

    /// Убирает все системные копии.
    func removeAllMirrors() async {
        let reminders = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []

        for reminder in reminders {
            guard let externalID = reminder.externalIdentifier else { continue }
            eventKit.removeMirror(identifier: externalID)
            reminder.externalIdentifier = nil
        }
        save()
    }

    /// Подтягивает изменения из системного приложения.
    ///
    /// Проверяется только одно направление: закрытие дела. Правки текста
    /// и времени в системных Напоминаниях сознательно игнорируются, иначе
    /// пришлось бы разрешать конфликты между двумя приложениями, а это
    /// сложность, которой продукт не оправдывает.
    func pullCompletions() async {
        guard isMirroringEnabled, eventKit.remindersAccess == .granted else { return }

        let reminders = fetchActiveReminders().filter { $0.externalIdentifier != nil }
        guard !reminders.isEmpty else { return }

        let identifiers = reminders.compactMap(\.externalIdentifier)
        let completed = eventKit.fetchCompletedIdentifiers(among: identifiers)
        guard !completed.isEmpty else { return }

        for reminder in reminders {
            guard let externalID = reminder.externalIdentifier,
                  completed.contains(externalID) else { continue }

            reminder.complete()
            notifications.cancel(for: reminder)
        }

        lastSyncAt = .now
        save()
        Log.data.notice("Закрыто напоминаний из системного приложения: \(completed.count)")
    }

    // MARK: Вспомогательное

    private func fetchActiveReminders() -> [Reminder] {
        let descriptor = FetchDescriptor<Reminder>(
            sortBy: [SortDescriptor(\.fireDate, order: .forward)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { !$0.isCompleted }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Состояние напоминаний не сохранено: \(error.localizedDescription)")
        }
    }
}
