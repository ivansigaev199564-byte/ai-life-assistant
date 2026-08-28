import Foundation

/// Сетевая сессия приложения.
///
/// Раньше все пять клиентов сидели на `URLSession.shared`, у которой общий
/// дисковый кэш. Ответы сервера с текстами записей и суммами трат оседали
/// в `Library/Caches` открытым текстом, не удалялись при выходе из аккаунта
/// и попадали в резервные копии. Дневник не должен лежать в кэше.
enum PrivateSession {

    /// Общая сессия без дискового кэша и без хранения cookie.
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Эфемерная конфигурация уже не пишет на диск, но кэш в памяти
        // тоже незачем: ответы читаются один раз.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["Cache-Control": "no-store"]
        // Ждать сеть, а не падать сразу: приложение офлайн-первое,
        // и запрос вполне может уйти в момент возврата связи.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()
}
