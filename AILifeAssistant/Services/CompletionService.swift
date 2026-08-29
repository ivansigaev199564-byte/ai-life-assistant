import Foundation
import Observation
import SwiftData
import WidgetKit

/// Единственный путь закрыть дело.
///
/// Отметка «выполнено» это не одно действие, а четыре: изменить модель,
/// снять локальное уведомление, обновить системные Напоминания и сообщить
/// синхронизации. Разложить их по представлениям значит рано или поздно
/// забыть одно из четырёх в очередном месте, и список дел начнёт врать.
///
/// Поэтому все экраны, виджет и системные интеграции ходят сюда.
@MainActor
@Observable
final class CompletionService {

    private let modelContext: ModelContext
    private let mirror: ReminderMirror?
    private let settings: AppSettings?
    private let haptics: HapticEngine?

    /// Сообщает синхронизации, что сущность изменилась.
    /// Назначается сборкой окружения, в тестах остаётся пустым.
    var onChanged: ((SyncEntityType, UUID) -> Void)?

    init(
        modelContext: ModelContext,
        mirror: ReminderMirror? = nil,
        settings: AppSettings? = nil,
        haptics: HapticEngine? = nil
    ) {
        self.modelContext = modelContext
        self.mirror = mirror
        self.settings = settings
        self.haptics = haptics
    }

    // MARK: Задачи

    func toggle(_ task: TaskItem) {
        setCompleted(!task.isCompleted, for: task)
    }

    func setCompleted(_ completed: Bool, for task: TaskItem) {
        guard task.isCompleted != completed else { return }
        task.setCompleted(completed)
        finish(.task, id: task.id)
    }

    // MARK: Напоминания

    func toggle(_ reminder: Reminder) {
        setCompleted(!reminder.isCompleted, for: reminder)
    }

    func setCompleted(_ completed: Bool, for reminder: Reminder) {
        guard reminder.isCompleted != completed else { return }
        reminder.setCompleted(completed)

        // Уведомление снимается сразу: телефон не должен звонить о деле,
        // которое человек только что закрыл. Возврат в работу так же
        // возвращает уведомление, если срок ещё не прошёл.
        //
        // В задачу уходит идентификатор, а не сам объект: запись может
        // исчезнуть, пока задача ждёт своей очереди.
        if let mirror {
            let identifier = reminder.id
            Task { await mirror.update(reminderID: identifier) }
        }

        finish(.reminder, id: reminder.id)
    }

    // MARK: Общее завершение

    private func finish(_ entityType: SyncEntityType, id: UUID) {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Отметка выполнения не сохранена: \(error.localizedDescription)")
            return
        }

        onChanged?(entityType, id)

        if settings?.hapticsEnabled ?? false {
            haptics?.selectionChanged()
        }

        // Виджет показывает ровно те дела, что здесь закрыты: без этого
        // на экране блокировки останется вчерашний список.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
