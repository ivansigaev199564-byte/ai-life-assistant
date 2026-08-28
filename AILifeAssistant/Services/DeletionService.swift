import Foundation
import Observation
import SwiftData
import WidgetKit

/// Единственный путь удалить запись.
///
/// Удаление это не одно действие, а четыре: снять уведомления созданных
/// напоминаний, убрать аудиофайл, стереть запись и сообщить синхронизации.
/// Раньше оно было переписано в шести местах, и ни одно из них не говорило
/// синхронизации ни слова: запись исчезала на телефоне, оставалась
/// на сервере и возвращалась после переустановки.
@MainActor
@Observable
final class DeletionService {

    private let modelContext: ModelContext
    private let recordings: RecordingStore
    private let mirror: ReminderMirror?

    /// Сообщает синхронизации, что запись удалена.
    var onDeleted: ((SyncEntityType, UUID) -> Void)?

    init(
        modelContext: ModelContext,
        recordings: RecordingStore = RecordingStore(),
        mirror: ReminderMirror? = nil
    ) {
        self.modelContext = modelContext
        self.recordings = recordings
        self.mirror = mirror
    }

    // MARK: Записи

    @discardableResult
    func delete(_ capture: CaptureItem) -> Bool {
        delete([capture]) == 1
    }

    /// Удаляет пачку записей.
    /// - Returns: сколько записей удалено.
    @discardableResult
    func delete(_ captures: [CaptureItem]) -> Int {
        guard !captures.isEmpty else { return 0 }

        var deletedIDs: [UUID] = []
        var reminderIDs: [UUID] = []
        var derived: [(SyncEntityType, UUID)] = []

        for capture in captures {
            // Уведомления снимаются до удаления: после каскада напоминаний
            // уже не будет, а телефон продолжит о них звонить.
            for reminder in capture.reminders {
                mirror?.unregister(reminder)
                reminderIDs.append(reminder.id)
            }

            // Производные сущности уходят каскадом, но сервер о каскаде
            // не знает: ему нужен список.
            derived += capture.notes.map { (.note, $0.id) }
            derived += capture.tasks.map { (.task, $0.id) }
            derived += capture.expenses.map { (.expense, $0.id) }

            if let fileName = capture.audioFileName {
                recordings.delete(fileName: fileName)
            }

            deletedIDs.append(capture.id)
            modelContext.delete(capture)
        }

        guard save(context: "удаление записей") else { return 0 }

        for id in deletedIDs { onDeleted?(.capture, id) }
        for id in reminderIDs { onDeleted?(.reminder, id) }
        for (type, id) in derived { onDeleted?(type, id) }

        WidgetCenter.shared.reloadAllTimelines()
        Log.data.notice("Удалено записей: \(deletedIDs.count)")

        return deletedIDs.count
    }

    // MARK: Люди и проекты

    @discardableResult
    func delete(_ project: Project) -> Bool {
        let id = project.id
        modelContext.delete(project)

        guard save(context: "удаление проекта") else { return false }
        onDeleted?(.project, id)
        return true
    }

    @discardableResult
    func delete(_ person: Person) -> Bool {
        let id = person.id
        modelContext.delete(person)

        guard save(context: "удаление человека") else { return false }
        onDeleted?(.person, id)
        return true
    }

    private func save(context: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            Log.data.error("Не удалось сохранить \(context, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }
}
