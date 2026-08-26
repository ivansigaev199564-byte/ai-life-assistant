import Foundation

/// Минимальный клиент PostgREST.
///
/// Написан на URLSession вместо готового SDK намеренно: приложению нужны
/// ровно две операции, upsert и выборка изменений после отметки времени.
/// Тянуть ради этого зависимость с собственным жизненным циклом
/// и требованиями к версии Swift избыточно.
struct SupabaseRESTClient: Sendable {

    enum ClientError: LocalizedError, Equatable {
        case notConfigured
        case unauthorized
        case server(status: Int, message: String)
        case transport(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Бэкенд не настроен"
            case .unauthorized: return "Устройство не авторизовано"
            case .server(let status, let message): return "Сервер вернул \(status): \(message)"
            case .transport(let details): return "Сетевая ошибка: \(details)"
            case .decoding(let details): return "Ответ не разобрался: \(details)"
            }
        }

        /// Есть ли смысл повторить.
        var isRetryable: Bool {
            switch self {
            case .transport: return true
            case .server(let status, _): return status == 429 || status >= 500
            case .notConfigured, .unauthorized, .decoding: return false
            }
        }
    }

    private let configuration: SupabaseConfiguration
    private let session: URLSession
    /// Токен пользователя. Без него запросы уходят с анонимными правами,
    /// а политики доступа не пропустят ни одной строки.
    private let accessToken: String?

    init(
        configuration: SupabaseConfiguration,
        accessToken: String?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: Операции

    /// Отправляет записи, обновляя существующие по первичному ключу.
    func upsert<Payload: Encodable>(_ payloads: [Payload], into table: String) async throws {
        guard !payloads.isEmpty else { return }

        var request = try makeRequest(path: table, method: "POST")
        // merge-duplicates превращает вставку в upsert, а minimal просит
        // сервер не присылать обратно тела записей: они нам не нужны.
        request.setValue(
            "resolution=merge-duplicates,return=minimal",
            forHTTPHeaderField: "Prefer"
        )
        request.httpBody = try Self.encoder.encode(payloads)

        _ = try await send(request)
    }

    /// Забирает записи, изменившиеся после указанного момента.
    func fetchChanges<Payload: Decodable>(
        from table: String,
        since: Date?,
        limit: Int = 500
    ) async throws -> [Payload] {
        var items = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "updated_at.asc"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        if let since {
            // gt, а не gte: иначе последняя запись прошлой выборки
            // будет приезжать снова на каждой синхронизации.
            items.append(
                URLQueryItem(name: "updated_at", value: "gt.\(Self.formatter.string(from: since))")
            )
        }

        let request = try makeRequest(path: table, method: "GET", queryItems: items)
        let data = try await send(request)

        do {
            return try Self.decoder.decode([Payload].self, from: data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    /// Вызывает функцию базы данных.
    func callFunction<Response: Decodable>(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> Response {
        var request = try makeRequest(path: "rpc/\(name)", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments)

        let data = try await send(request)

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    // MARK: Транспорт

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard let accessToken, !accessToken.isEmpty else {
            throw ClientError.unauthorized
        }

        var components = URLComponents(
            url: configuration.restURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            throw ClientError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ClientError.transport("операция отменена")
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("ответ без кода состояния")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw ClientError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.server(status: http.statusCode, message: message)
        }
    }

    // MARK: Кодирование

    /// Формат дат один на всё общение с сервером: PostgREST принимает
    /// и отдаёт ISO 8601, и любое расхождение здесь ломает выборку изменений.
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = formatter.date(from: value) { return date }

            // Сервер может отдать время без дробной части: она появляется
            // не всегда, и на этом ломается строгий разбор.
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Не удалось разобрать дату: \(value)"
            )
        }
        return decoder
    }()
}
