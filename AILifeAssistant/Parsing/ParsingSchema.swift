import Foundation

/// Схема ответа и системный промпт для облачной модели.
///
/// Один источник правды: та же схема уедет в Edge Function на Этапе 3,
/// поэтому она описана данными, а не зашита в текст запроса.
enum ParsingSchema {

    /// Имя инструмента, через который модель возвращает структуру.
    /// Строгий вызов инструмента надёжнее просьбы «ответь JSON»:
    /// схема проверяется на стороне API, а не парсером на устройстве.
    static let toolName = "extract_intents"

    static let toolDescription = """
        Извлекает из голосовой заметки пользователя все действия: заметки, \
        задачи, напоминания и расходы. Одна фраза может содержать несколько \
        действий одновременно.
        """

    /// JSON Schema аргументов инструмента.
    static var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "description": "Все действия, найденные во фразе, по одному элементу на действие",
                    "items": itemSchema
                ],
                "people": [
                    "type": "array",
                    "description": "Имена людей, упомянутых во фразе, в именительном падеже",
                    "items": ["type": "string"]
                ],
                "projects": [
                    "type": "array",
                    "description": "Названия проектов или сфер, к которым относится запись",
                    "items": ["type": "string"]
                ],
                "language": [
                    "type": "string",
                    "description": "Язык фразы: ru или en"
                ],
                "confidence": [
                    "type": "number",
                    "description": "Общая уверенность в разборе, от 0 до 1"
                ]
            ],
            "required": ["items", "confidence"],
            // Строгий режим инструмента требует явного запрета лишних полей,
            // иначе API отклонит схему.
            "additionalProperties": false
        ]
    }

    private static var itemSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ParsedItemKind.allCases.map(\.rawValue),
                    "description": "Тип действия"
                ],
                "title": [
                    "type": "string",
                    "description": "Суть действия без служебных слов вроде «напомни» или «нужно»"
                ],
                "details": [
                    "type": "string",
                    "description": "Уточнение, если оно есть во фразе"
                ],
                "due_date": [
                    "type": "string",
                    "description": "Дата и время в ISO 8601 с часовым поясом пользователя, пустая строка если срока нет"
                ],
                "priority": [
                    "type": "string",
                    "enum": Priority.allCases.map(\.rawValue),
                    "description": "Приоритет, если он явно следует из фразы"
                ],
                "amount": [
                    "type": "number",
                    "description": "Сумма расхода, 0 если это не трата"
                ],
                "currency_code": [
                    "type": "string",
                    "description": "Код валюты из трёх букв по ISO 4217"
                ],
                "category": [
                    "type": "string",
                    "enum": ExpenseCategory.allCases.map(\.rawValue),
                    "description": "Категория расхода"
                ],
                "merchant": [
                    "type": "string",
                    "description": "Где потрачено, если названо"
                ],
                "people": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Люди, относящиеся именно к этому действию"
                ],
                "confidence": [
                    "type": "number",
                    "description": "Уверенность в этом конкретном действии, от 0 до 1"
                ]
            ],
            "required": ["kind", "title", "confidence"],
            "additionalProperties": false
        ]
    }

    // MARK: Промпт

    static let systemPrompt = """
        Ты разбираешь короткие голосовые заметки на осмысленные действия.
        Пользователь говорит на русском или английском, часто сбивчиво \
        и с оговорками распознавания речи.

        Определяй тип каждого действия так:
        - expense, если названа потраченная сумма;
        - reminder, если есть конкретное время или прямая просьба напомнить;
        - task, если есть действие, но точного времени нет;
        - note, если человек просто зафиксировал мысль.

        Одна фраза может содержать несколько действий: «купил кофе за триста \
        и напомни завтра позвонить маме» это расход и напоминание. Возвращай \
        каждое отдельным элементом.

        Требования к полям:
        - в title пиши только суть, без «напомни», «нужно», «не забыть»;
        - даты приводи к ISO 8601 в часовом поясе пользователя, относительные \
        выражения считай от переданного текущего момента;
        - имена людей приводи к именительному падежу: «Мише» становится «Миша»;
        - если сумма названа без валюты, используй валюту по умолчанию.

        Про уверенность: ставь честную оценку. Если фраза оборвана, \
        противоречива или распознана явно с ошибками, ставь значение ниже 0.7, \
        и приложение покажет запись пользователю на проверку вместо того, \
        чтобы создать неверную сущность. Ничего не выдумывай: пустое поле \
        лучше правдоподобной выдумки.
        """

    /// Пользовательская часть запроса с контекстом.
    static func userPrompt(text: String, context: ParsingContext) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = context.timeZone

        var lines = [
            "Текущий момент: \(formatter.string(from: context.referenceDate))",
            "Часовой пояс: \(context.timeZone.identifier)",
            "Валюта по умолчанию: \(context.defaultCurrencyCode)"
        ]

        if !context.knownPeople.isEmpty {
            lines.append("Известные люди: \(context.knownPeople.joined(separator: ", "))")
        }
        if !context.knownProjects.isEmpty {
            lines.append("Известные проекты: \(context.knownProjects.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Фраза: \(text)")
        return lines.joined(separator: "\n")
    }
}
