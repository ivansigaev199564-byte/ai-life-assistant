import Foundation

/// Прямое обращение к Messages API Anthropic.
///
/// Модель обязана вернуть структуру через вызов инструмента: схема
/// проверяется на стороне API, поэтому на устройство приходит уже валидный
/// объект, а не свободный текст, который пришлось бы разбирать вручную.
///
/// Ключ в приложении держать нельзя, поэтому в релизных сборках работает
/// EdgeFunctionClient, а этот клиент нужен для отладки и как справочная
/// реализация контракта.
struct AnthropicClient: LLMClient {

    private let configuration: APIConfiguration
    private let apiKey: String?
    private let session: URLSession

    init(
        configuration: APIConfiguration = .default,
        apiKey: String? = nil,
        session: URLSession = PrivateSession.shared
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.session = session
    }

    var isConfigured: Bool {
        configuration.isCloudEnabled
            && configuration.backend == .anthropicDirect
            && !(apiKey ?? "").isEmpty
    }

    func extractIntents(text: String, context: ParsingContext) async throws -> ParsedIntent {
        guard isConfigured else { throw ParsingError.engineUnavailable(.cloud) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParsingError.emptyInput }

        let started = Date()
        let body = try requestBody(text: trimmed, context: context)
        let data = try await send(body: body)
        let payload = try Self.extractToolPayload(from: data)

        return try IntentResponseDecoder.decode(
            payload,
            context: context,
            sourceText: trimmed,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: Запрос

    private func requestBody(text: String, context: ParsingContext) throws -> Data {
        let payload: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            // Извлечение сущностей из одной фразы простая задача: низкое
            // усилие заметно сокращает и задержку, и стоимость запроса.
            "output_config": ["effort": configuration.effort],
            "system": ParsingSchema.systemPrompt,
            "tools": [
                [
                    "name": ParsingSchema.toolName,
                    "description": ParsingSchema.toolDescription,
                    "input_schema": ParsingSchema.inputSchema,
                    // Строгий режим гарантирует, что аргументы совпадут
                    // со схемой, и снимает с приложения проверку полей.
                    "strict": true
                ]
            ],
            // Ответ обязан быть вызовом инструмента, а не свободным текстом.
            "tool_choice": ["type": "tool", "name": ParsingSchema.toolName],
            "messages": [
                [
                    "role": "user",
                    "content": ParsingSchema.userPrompt(text: text, context: context)
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func send(body: Data) async throws -> Data {
        var attempt = 0

        while true {
            do {
                return try await performRequest(body: body)
            } catch let error as ParsingError {
                attempt += 1
                guard error.isRetryable, attempt <= configuration.maxRetries else { throw error }

                // Пауза растёт по степеням двойки, а при явном указании
                // сервера ждём именно столько, сколько он попросил.
                let delay: TimeInterval
                if case .rateLimited(let retryAfter) = error, let retryAfter {
                    delay = retryAfter
                } else {
                    delay = pow(2, Double(attempt - 1))
                }

                Log.data.notice("Повтор запроса разбора через \(delay, format: .fixed(precision: 1)) с")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func performRequest(body: Data) async throws -> Data {
        var request = URLRequest(url: APIConfiguration.anthropicMessagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(APIConfiguration.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = body

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
            return data
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw ParsingError.rateLimited(retryAfter: retryAfter)
        case 500, 502, 503, 529:
            // Ошибки сервиса и перегрузка лечатся повтором.
            throw ParsingError.network("код \(http.statusCode)")
        default:
            throw ParsingError.invalidResponse(Self.errorMessage(from: data, status: http.statusCode))
        }
    }

    // MARK: Ответ

    /// Достаёт аргументы вызова инструмента из блоков ответа.
    static func extractToolPayload(from data: Data) throws -> IntentResponseDecoder.Payload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParsingError.invalidResponse("ответ не является объектом JSON")
        }

        // Отказ приходит с кодом 200, поэтому проверяем причину остановки
        // до того, как искать содержимое.
        if let stopReason = root["stop_reason"] as? String, stopReason == "refusal" {
            throw ParsingError.invalidResponse("модель отказалась разбирать фразу")
        }

        guard let content = root["content"] as? [[String: Any]] else {
            throw ParsingError.invalidResponse("в ответе нет блоков содержимого")
        }

        guard let toolUse = content.first(where: { block in
            (block["type"] as? String) == "tool_use"
                && (block["name"] as? String) == ParsingSchema.toolName
        }), let input = toolUse["input"] else {
            throw ParsingError.invalidResponse("модель не вызвала инструмент разбора")
        }

        let inputData = try JSONSerialization.data(withJSONObject: input)
        do {
            return try JSONDecoder().decode(IntentResponseDecoder.Payload.self, from: inputData)
        } catch {
            throw ParsingError.invalidResponse("аргументы инструмента не разобрались: \(error)")
        }
    }

    /// Текст ошибки из тела ответа, если он там есть.
    private static func errorMessage(from data: Data, status: Int) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "код \(status)"
        }
        return "\(status): \(message)"
    }
}
