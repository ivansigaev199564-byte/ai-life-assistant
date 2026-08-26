import Foundation

/// Разбор через собственную функцию-посредник.
///
/// Правильный путь для релиза: ключ модели лежит на сервере, устройство
/// авторизуется своим токеном, а тело запроса и формат ответа те же, что
/// у прямого клиента. Функция появится вместе с Supabase на Этапе 3,
/// поэтому здесь описан контракт и транспорт, но не серверная часть.
struct EdgeFunctionClient: LLMClient {

    /// Тело запроса к функции. Схему и промпт держит сервер: их незачем
    /// гонять по сети на каждый запрос и незачем показывать клиенту.
    private struct RequestBody: Encodable {
        let text: String
        let referenceDate: Date
        let timeZoneIdentifier: String
        let languageCode: String?
        let defaultCurrencyCode: String
        let knownPeople: [String]
        let knownProjects: [String]
    }

    private let configuration: APIConfiguration
    /// Токен пользователя. На Этапе 3 его выдаёт Supabase Auth.
    private let accessToken: String?
    private let session: URLSession

    init(
        configuration: APIConfiguration = .default,
        accessToken: String? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.accessToken = accessToken
        self.session = session
    }

    var isConfigured: Bool {
        configuration.isCloudEnabled
            && configuration.backend == .edgeFunction
            && configuration.edgeFunctionURL != nil
    }

    func extractIntents(text: String, context: ParsingContext) async throws -> ParsedIntent {
        guard isConfigured, let url = configuration.edgeFunctionURL else {
            throw ParsingError.engineUnavailable(.cloud)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParsingError.emptyInput }

        let started = Date()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase

        request.httpBody = try encoder.encode(
            RequestBody(
                text: trimmed,
                referenceDate: context.referenceDate,
                timeZoneIdentifier: context.timeZone.identifier,
                languageCode: context.languageCode,
                defaultCurrencyCode: context.defaultCurrencyCode,
                knownPeople: context.knownPeople,
                knownProjects: context.knownProjects
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ParsingError.cancelled
        } catch {
            throw ParsingError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ParsingError.invalidResponse("ответ без кода состояния")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ParsingError.invalidResponse("устройство не авторизовано на сервере")
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw ParsingError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw ParsingError.network("сервер вернул \(http.statusCode)")
        default:
            throw ParsingError.invalidResponse("код \(http.statusCode)")
        }

        // Функция отдаёт те же аргументы инструмента, что и Anthropic:
        // так обе реализации разбираются одним декодером.
        let payload: IntentResponseDecoder.Payload
        do {
            payload = try JSONDecoder().decode(IntentResponseDecoder.Payload.self, from: data)
        } catch {
            throw ParsingError.invalidResponse("ответ функции не разобрался: \(error)")
        }

        return try IntentResponseDecoder.decode(
            payload,
            context: context,
            sourceText: trimmed,
            duration: Date().timeIntervalSince(started)
        )
    }
}

/// Облачный парсер поверх любого клиента.
struct CloudParser: IntentParsing {

    let engine: ParsingEngine = .cloud
    let requiresNetwork = true

    private let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    var isAvailable: Bool {
        get async { client.isConfigured }
    }

    func parse(text: String, context: ParsingContext) async throws -> ParsedIntent {
        guard client.isConfigured else { throw ParsingError.engineUnavailable(.cloud) }
        return try await client.extractIntents(text: text, context: context)
    }
}
