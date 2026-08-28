import { type AuthContext, authenticate } from "../_shared/auth.ts";
import { consumeQuota, QuotaExceededError } from "../_shared/quota.ts";
import { boundedList, LIMITS, optionalString, requireString, ValidationError } from "../_shared/validate.ts";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/cors.ts";
import {
  buildUserPrompt,
  INPUT_SCHEMA,
  type ParseRequest,
  SYSTEM_PROMPT,
  TOOL_DESCRIPTION,
  TOOL_NAME,
} from "../_shared/schema.ts";

/// Разбор голосовой заметки моделью Claude.
///
/// Смысл этой функции в одном: ключ модели остаётся на сервере. Приложение
/// присылает только текст и контекст, а ответ получает уже разобранным
/// по строгой схеме.

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

/// Модель задаётся переменной окружения: сменить её на сервере проще,
/// чем выпускать новую версию приложения.
const MODEL = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-opus-5";

/// Извлечение сущностей из одной фразы это простая задача, и низкое
/// усилие заметно сокращает и задержку, и стоимость запроса.
const EFFORT = Deno.env.get("ANTHROPIC_EFFORT") ?? "low";

const MAX_ATTEMPTS = 3;

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return errorResponse("Поддерживается только POST", 405);
  }

  let auth: AuthContext;
  try {
    auth = await authenticate(request);
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "Нет доступа", 401);
  }

  // Предел на пользователя. Без него один вошедший через Apple может
  // прогнать за ночь тысячи платных запросов через чужой ключ.
  try {
    await consumeQuota(auth, "parse");
  } catch (error) {
    if (error instanceof QuotaExceededError) {
      return errorResponse(error.message, 429);
    }
    return errorResponse("Не удалось проверить предел обращений", 503);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return errorResponse("Ключ модели не задан на сервере", 500);
  }

  let raw: Record<string, unknown>;
  try {
    raw = await request.json();
  } catch {
    return errorResponse("Тело запроса не является JSON");
  }

  // Проверяется всё тело, а не только текст: списки известных людей
  // и проектов раньше уходили в промпт как есть, без ограничений
  // по количеству, длине и типу.
  let payload: ParseRequest;
  try {
    payload = {
      text: requireString(raw.text, "text", LIMITS.text),
      reference_date: requireString(raw.reference_date, "reference_date", 40),
      time_zone_identifier: optionalString(raw.time_zone_identifier, "time_zone_identifier", LIMITS.timeZone) ?? "UTC",
      default_currency_code: optionalString(raw.default_currency_code, "default_currency_code", LIMITS.currencyCode) ?? "RUB",
      language_code: optionalString(raw.language_code, "language_code", LIMITS.languageCode),
      known_people: boundedList(raw.known_people, "known_people"),
      known_projects: boundedList(raw.known_projects, "known_projects"),
    };
  } catch (error) {
    if (error instanceof ValidationError) {
      return errorResponse(error.message);
    }
    return errorResponse("Тело запроса не прошло проверку");
  }

  const text = payload.text;

  const body = {
    model: MODEL,
    max_tokens: 4096,
    output_config: { effort: EFFORT },
    system: SYSTEM_PROMPT,
    tools: [
      {
        name: TOOL_NAME,
        description: TOOL_DESCRIPTION,
        input_schema: INPUT_SCHEMA,
        // Строгий режим гарантирует, что аргументы совпадут со схемой.
        strict: true,
      },
    ],
    // Ответ обязан быть вызовом инструмента, а не свободным текстом.
    tool_choice: { type: "tool", name: TOOL_NAME },
    messages: [{ role: "user", content: buildUserPrompt(payload) }],
  };

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const response = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": apiKey,
          "anthropic-version": ANTHROPIC_VERSION,
        },
        body: JSON.stringify(body),
      });

      // Перегрузка и лимиты лечатся повтором, остальные коды нет.
      if (response.status === 429 || response.status >= 500) {
        if (attempt === MAX_ATTEMPTS) {
          return errorResponse("Модель временно недоступна", 503);
        }
        const retryAfter = Number(response.headers.get("retry-after"));
        const delay = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 2 ** (attempt - 1) * 1000;
        await new Promise((resolve) => setTimeout(resolve, delay));
        continue;
      }

      if (!response.ok) {
        const details = await response.text();
        // В лог уходит только код: тело ответа модели содержит эхо запроса,
        // то есть текст пользователя.
        console.error("Ошибка модели", response.status);
        return errorResponse("Модель отклонила запрос", 502);
      }

      const result = await response.json();

      // Отказ приходит с кодом 200, поэтому проверяется отдельно.
      if (result.stop_reason === "refusal") {
        return errorResponse("Модель отказалась разбирать фразу", 422);
      }

      const toolUse = (result.content ?? []).find(
        (block: { type?: string; name?: string }) =>
          block.type === "tool_use" && block.name === TOOL_NAME,
      );

      if (!toolUse?.input) {
        return errorResponse("Модель не вызвала инструмент разбора", 502);
      }

      return jsonResponse(toolUse.input);
    } catch (error) {
      if (attempt === MAX_ATTEMPTS) {
        console.error(
          "Сетевая ошибка при обращении к модели",
          error instanceof Error ? error.name : "unknown",
        );
        return errorResponse("Не удалось связаться с моделью", 502);
      }
      await new Promise((resolve) => setTimeout(resolve, 2 ** (attempt - 1) * 1000));
    }
  }

  return errorResponse("Разбор не удался", 500);
});
