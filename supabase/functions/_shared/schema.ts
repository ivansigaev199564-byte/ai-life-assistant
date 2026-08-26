/// Схема разбора и системный промпт.
///
/// Дубликат того, что описано в приложении, но живёт здесь намеренно:
/// схема должна ехать в модель с сервера, а не с устройства. Иначе старая
/// версия приложения будет присылать устаревшую схему, и ответы начнут
/// расходиться между пользователями с разными версиями.

export const TOOL_NAME = "extract_intents";

export const TOOL_DESCRIPTION =
  "Извлекает из голосовой заметки пользователя все действия: заметки, " +
  "задачи, напоминания и расходы. Одна фраза может содержать несколько " +
  "действий одновременно.";

export const ITEM_KINDS = ["note", "task", "reminder", "expense"] as const;
export const PRIORITIES = ["none", "low", "medium", "high"] as const;
export const CATEGORIES = [
  "food", "transport", "housing", "health", "entertainment",
  "shopping", "education", "travel", "services", "other",
] as const;

export const INPUT_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      description: "Все действия, найденные во фразе, по одному элементу на действие",
      items: {
        type: "object",
        properties: {
          kind: { type: "string", enum: ITEM_KINDS, description: "Тип действия" },
          title: {
            type: "string",
            description: "Суть действия без служебных слов вроде «напомни» или «нужно»",
          },
          details: { type: "string", description: "Уточнение, если оно есть во фразе" },
          due_date: {
            type: "string",
            description:
              "Дата и время в ISO 8601 с часовым поясом пользователя, пустая строка если срока нет",
          },
          priority: { type: "string", enum: PRIORITIES, description: "Приоритет" },
          amount: { type: "number", description: "Сумма расхода, 0 если это не трата" },
          currency_code: { type: "string", description: "Код валюты из трёх букв" },
          category: { type: "string", enum: CATEGORIES, description: "Категория расхода" },
          merchant: { type: "string", description: "Где потрачено, если названо" },
          people: {
            type: "array",
            items: { type: "string" },
            description: "Люди, относящиеся именно к этому действию",
          },
          confidence: {
            type: "number",
            description: "Уверенность в этом конкретном действии, от 0 до 1",
          },
        },
        required: ["kind", "title", "confidence"],
        additionalProperties: false,
      },
    },
    people: {
      type: "array",
      items: { type: "string" },
      description: "Имена людей в именительном падеже",
    },
    projects: {
      type: "array",
      items: { type: "string" },
      description: "Названия проектов или сфер",
    },
    language: { type: "string", description: "Язык фразы: ru или en" },
    confidence: { type: "number", description: "Общая уверенность разбора, от 0 до 1" },
  },
  required: ["items", "confidence"],
  additionalProperties: false,
};

export const SYSTEM_PROMPT = `Ты разбираешь короткие голосовые заметки на осмысленные действия.
Пользователь говорит на русском или английском, часто сбивчиво и с оговорками распознавания речи.

Определяй тип каждого действия так:
- expense, если названа потраченная сумма;
- reminder, если есть конкретное время или прямая просьба напомнить;
- task, если есть действие, но точного времени нет;
- note, если человек просто зафиксировал мысль.

Одна фраза может содержать несколько действий: «купил кофе за триста и напомни завтра позвонить маме» это расход и напоминание. Возвращай каждое отдельным элементом.

Требования к полям:
- в title пиши только суть, без «напомни», «нужно», «не забыть»;
- даты приводи к ISO 8601 в часовом поясе пользователя, относительные выражения считай от переданного текущего момента;
- имена людей приводи к именительному падежу: «Мише» становится «Миша»;
- если сумма названа без валюты, используй валюту по умолчанию.

Про уверенность: ставь честную оценку. Если фраза оборвана, противоречива или распознана явно с ошибками, ставь значение ниже 0.7, и приложение покажет запись пользователю на проверку вместо того, чтобы создать неверную сущность. Ничего не выдумывай: пустое поле лучше правдоподобной выдумки.`;

export interface ParseRequest {
  text: string;
  reference_date: string;
  time_zone_identifier: string;
  language_code?: string | null;
  default_currency_code: string;
  known_people?: string[];
  known_projects?: string[];
}

export function buildUserPrompt(request: ParseRequest): string {
  const lines = [
    `Текущий момент: ${request.reference_date}`,
    `Часовой пояс: ${request.time_zone_identifier}`,
    `Валюта по умолчанию: ${request.default_currency_code}`,
  ];

  if (request.known_people?.length) {
    lines.push(`Известные люди: ${request.known_people.join(", ")}`);
  }
  if (request.known_projects?.length) {
    lines.push(`Известные проекты: ${request.known_projects.join(", ")}`);
  }

  lines.push("", `Фраза: ${request.text}`);
  return lines.join("\n");
}
