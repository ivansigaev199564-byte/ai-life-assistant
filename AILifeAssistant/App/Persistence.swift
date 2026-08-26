import Foundation
import SwiftData

/// Конфигурация хранилища SwiftData.
enum Persistence {

    /// Схема со всеми сущностями. Порядок значения не имеет,
    /// но список должен быть полным: пропущенная модель ломает связи.
    static let schema = Schema([
        CaptureItem.self,
        Note.self,
        TaskItem.self,
        Reminder.self,
        Expense.self,
        Person.self,
        Project.self
    ])

    /// Идентификатор группы приложений. Общий контейнер нужен, чтобы
    /// расширения писали в ту же базу, что и приложение.
    static let appGroupIdentifier = "group.com.ivans.ailifeassistant"

    /// Доступна ли группа приложений в этой сборке.
    ///
    /// Проверять обязательно до создания контейнера: при отсутствии права
    /// на группу SwiftData вызывает fatalError внутри себя, и перехватить
    /// его через do/catch нельзя. Так падает сборка без подписи (в том числе
    /// в CI) и устройство, на котором группа не заведена в профиле.
    static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil
    }

    /// Создаёт контейнер. Общий контейнер группы используется, только если
    /// он реально доступен: без App Group приложение обязано работать,
    /// просто расширения не увидят данные.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: configuration)
        }

        if isAppGroupAvailable {
            let configuration = ModelConfiguration(
                groupContainer: .identifier(appGroupIdentifier)
            )
            return try ModelContainer(for: schema, configurations: configuration)
        }

        Log.data.notice("Группа приложений недоступна, используется локальное хранилище")
        return try ModelContainer(for: schema, configurations: ModelConfiguration())
    }

    /// Контейнер для тестов и превью: живёт в памяти и не трогает диск.
    static func makePreviewContainer() -> ModelContainer {
        do {
            return try makeContainer(inMemory: true)
        } catch {
            // В превью падать некуда: без контейнера SwiftUI не отрисует ничего.
            fatalError("Не удалось создать контейнер для превью: \(error)")
        }
    }
}
