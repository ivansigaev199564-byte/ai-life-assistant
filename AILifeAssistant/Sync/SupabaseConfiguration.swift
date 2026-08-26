import Foundation

/// Адрес проекта и публичный ключ.
///
/// Значения берутся из Info.plist, куда попадают из файла настроек сборки,
/// который не хранится в репозитории. Публичный ключ не секрет сам по себе:
/// он даёт доступ только к тому, что разрешают политики доступа в базе,
/// а они пускают пользователя лишь к его собственным строкам.
struct SupabaseConfiguration: Sendable, Equatable {

    let projectURL: URL
    let anonKey: String

    /// Настроен ли бэкенд. Пока нет, приложение работает полностью локально.
    static var isConfigured: Bool { current != nil }

    /// Конфигурация из Info.plist или nil, если ключи не заданы.
    static let current: SupabaseConfiguration? = {
        let bundle = Bundle.main

        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            !urlString.isEmpty,
            let url = URL(string: urlString),
            let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !key.isEmpty
        else {
            return nil
        }

        return SupabaseConfiguration(projectURL: url, anonKey: key)
    }()

    var restURL: URL { projectURL.appendingPathComponent("rest/v1") }
    var authURL: URL { projectURL.appendingPathComponent("auth/v1") }
    var functionsURL: URL { projectURL.appendingPathComponent("functions/v1") }
}
