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

    /// Создаёт контейнер. Сначала пробует общий контейнер группы,
    /// при неудаче откатывается на локальный: без App Group приложение
    /// обязано работать, просто расширения не увидят данные.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: configuration)
        }

        do {
            let configuration = ModelConfiguration(
                groupContainer: .identifier(appGroupIdentifier)
            )
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Log.data.notice("""
                Общий контейнер группы недоступен (\(error.localizedDescription)), \
                используется локальное хранилище
                """)
            let fallback = ModelConfiguration()
            return try ModelContainer(for: schema, configurations: fallback)
        }
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
