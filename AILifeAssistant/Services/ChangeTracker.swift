import Foundation
import Observation

/// Сообщает синхронизации, что запись изменилась.
///
/// Флаг на модели ставился в дюжине мест, а в очередь отправки попадало
/// только то, что прошло через два замыкания в сборке приложения. Правки
/// с экранов (переименование проекта, подтверждение разбора, объединение
/// людей) до сервера не доходили вовсе: локально всё выглядело сохранённым,
/// а на другом устройстве оставалось старым.
@MainActor
@Observable
final class ChangeTracker {

    /// Назначается сборкой приложения. В предпросмотре и тестах пусто.
    var onChanged: ((SyncEntityType, UUID) -> Void)?

    init(onChanged: ((SyncEntityType, UUID) -> Void)? = nil) {
        self.onChanged = onChanged
    }

    func record(_ entityType: SyncEntityType, id: UUID) {
        onChanged?(entityType, id)
    }
}
