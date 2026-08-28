import Foundation

/// Общие настройки приложения и расширений.
///
/// Раньше идентификатор группы был записан строкой в трёх местах, и одно
/// из них уже разъехалось с остальными: интент Пункта управления писал флаг,
/// который никто не читал. Теперь имя группы и ключи живут в одном месте,
/// доступном и приложению, и виджетам.
enum SharedDefaults {

    /// Группа приложений. Должна совпадать с App Group в возможностях таргетов.
    static let suiteName = "group.com.ivans.ailifeassistant"

    /// Общее хранилище. nil, если группа не сконфигурирована: приложение
    /// обязано работать и без неё, просто без обмена с расширениями.
    static var group: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    enum Key {
        /// Кнопка Пункта управления просит начать запись сразу после запуска.
        static let pendingCapture = "pendingCaptureFromControl"
    }

    // MARK: Запрос захвата от расширения

    /// Просит приложение начать запись, как только оно окажется на экране.
    static func requestCapture() {
        group?.set(true, forKey: Key.pendingCapture)
    }

    /// Забирает запрос, если он был. Повторный вызов вернёт false:
    /// одно нажатие должно давать ровно одну запись.
    static func consumeCaptureRequest() -> Bool {
        guard let group, group.bool(forKey: Key.pendingCapture) else { return false }
        group.removeObject(forKey: Key.pendingCapture)
        return true
    }
}
