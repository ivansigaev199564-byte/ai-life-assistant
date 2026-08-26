import { authenticate } from "../_shared/auth.ts";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/cors.ts";

/// Генерация эмбеддингов для смыслового поиска.
///
/// Функция принимает список записей, считает векторы и складывает их
/// в таблицу embeddings от имени вызывающего пользователя, поэтому
/// политики доступа продолжают работать: чужие строки не записать.

const OPENAI_URL = "https://api.openai.com/v1/embeddings";

/// text-embedding-3-small: дёшево, 1536 измерений, русский и английский
/// живут в одном пространстве. Последнее важно: запись «купил кофе»
/// должна находиться по запросу «coffee».
const MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";

/// Размер пачки. Модель принимает массив строк за один запрос,
/// и это на порядок дешевле, чем по одной.
const MAX_BATCH = 64;

interface EmbedItem {
  entity_id: string;
  entity_type: "capture" | "note" | "task" | "reminder" | "expense";
  source_text: string;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return errorResponse("Поддерживается только POST", 405);
  }

  let auth;
  try {
    auth = await authenticate(request);
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "Нет доступа", 401);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    return errorResponse("Ключ модели эмбеддингов не задан на сервере", 500);
  }

  let items: EmbedItem[];
  try {
    const payload = await request.json();
    items = payload.items ?? [];
  } catch {
    return errorResponse("Тело запроса не является JSON");
  }

  // Пустые тексты отбрасываем сразу: вектор от пустой строки бесполезен,
  // но стоит денег.
  const prepared = items
    .filter((item) => item.source_text?.trim())
    .slice(0, MAX_BATCH)
    .map((item) => ({ ...item, source_text: item.source_text.trim().slice(0, 8000) }));

  if (prepared.length === 0) {
    return jsonResponse({ embedded: 0 });
  }

  let vectors: number[][];
  try {
    const response = await fetch(OPENAI_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: MODEL,
        input: prepared.map((item) => item.source_text),
      }),
    });

    if (!response.ok) {
      const details = await response.text();
      console.error("Ошибка эмбеддингов", response.status, details);
      return errorResponse("Не удалось посчитать векторы", 502);
    }

    const result = await response.json();
    // Порядок ответов совпадает с порядком входа, но полагаться на это
    // вслепую нельзя: сортируем по индексу явно.
    vectors = (result.data ?? [])
      .slice()
      .sort((left: { index: number }, right: { index: number }) => left.index - right.index)
      .map((entry: { embedding: number[] }) => entry.embedding);
  } catch (error) {
    console.error("Сетевая ошибка при расчёте векторов", error);
    return errorResponse("Сервис эмбеддингов недоступен", 502);
  }

  if (vectors.length !== prepared.length) {
    return errorResponse("Число векторов не совпало с числом записей", 502);
  }

  const rows = prepared.map((item, index) => ({
    user_id: auth.userId,
    entity_id: item.entity_id,
    entity_type: item.entity_type,
    embedding: vectors[index],
    source_text: item.source_text,
    model: MODEL,
  }));

  // Запись идёт от имени пользователя: политики доступа остаются в силе.
  const { error } = await auth.client
    .from("embeddings")
    .upsert(rows, { onConflict: "entity_id,entity_type" });

  if (error) {
    console.error("Не удалось сохранить векторы", error);
    return errorResponse("Векторы посчитаны, но не сохранены", 500);
  }

  return jsonResponse({ embedded: rows.length, model: MODEL });
});
