import { authenticate } from "../_shared/auth.ts";
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

  try {
    await authenticate(request);
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "Нет доступа", 401);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return errorResponse("Ключ модели не задан на сервере", 500);
  }

  let payload: ParseRequest;
  try {
    payload = await request.json();
  } catch {
    return errorResponse("Тело запроса не является JSON");
  }

  const text = (payload.text ?? "").trim();
  if (!text) {
    return errorResponse("Пустой текст, разбирать нечего");
  }
  // Ограничение длины: голосовая заметка на десять минут это не наш случай,
  // а вот случайно отправленный огромный текст обойдётся дорого.
  if (text.length > 4000) {
    return errorResponse("Текст длиннее допустимого предела");
  }

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
        console.error("Ошибка модели", response.status, details);
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
        console.error("Сетевая ошибка при обращении к модели", error);
        return errorResponse("Не удалось связаться с моделью", 502);
      }
      await new Promise((resolve) => setTimeout(resolve, 2 ** (attempt - 1) * 1000));
    }
  }

  return errorResponse("Разбор не удался", 500);
});
