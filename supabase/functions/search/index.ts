import { type AuthContext, authenticate } from "../_shared/auth.ts";
import { consumeQuota, QuotaExceededError } from "../_shared/quota.ts";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/cors.ts";

/// Гибридный поиск по всем записям пользователя.
///
/// Функция делает два шага за один запрос: считает вектор поискового
/// запроса и передаёт его в SQL-функцию hybrid_search вместе с текстом.
/// Разделять это на два обращения с устройства значило бы удвоить задержку
/// на самом чувствительном к ней сценарии.

const OPENAI_URL = "https://api.openai.com/v1/embeddings";
const MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";

interface SearchRequest {
  query: string;
  limit?: number;
  /// Смысловой поиск можно выключить: на коротких запросах вроде «кофе»
  /// полнотекстовый точнее, а вектор только добавляет шум.
  semantic?: boolean;
}

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

  // Предел на пользователя: платный вызов не должен зависеть только от
  // того, что человек сумел войти через Apple.
  try {
    await consumeQuota(auth, "search");
  } catch (error) {
    if (error instanceof QuotaExceededError) {
      return errorResponse(error.message, 429);
    }
    return errorResponse("Не удалось проверить предел обращений", 503);
  }

  let payload: SearchRequest;
  try {
    payload = await request.json();
  } catch {
    return errorResponse("Тело запроса не является JSON");
  }

  const query = (payload.query ?? "").trim();
  if (!query) {
    return jsonResponse({ results: [] });
  }

  const limit = Math.min(Math.max(payload.limit ?? 20, 1), 50);
  const wantsSemantic = payload.semantic ?? query.length >= 8;

  let embedding: number[] | null = null;

  if (wantsSemantic) {
    const apiKey = Deno.env.get("OPENAI_API_KEY");

    if (apiKey) {
      try {
        const response = await fetch(OPENAI_URL, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({ model: MODEL, input: query }),
        });

        if (response.ok) {
          const result = await response.json();
          embedding = result.data?.[0]?.embedding ?? null;
        } else {
          console.error("Вектор запроса не посчитан", response.status);
        }
      } catch (error) {
        // Смысловой поиск не критичен: без вектора функция отработает
        // на одном полнотекстовом, и пользователь получит результат.
        console.error("Сервис эмбеддингов недоступен", error instanceof Error ? error.name : "unknown");
      }
    }
  }

  const { data, error } = await auth.client.rpc("hybrid_search", {
    query_text: query,
    query_embedding: embedding,
    match_count: limit,
  });

  if (error) {
    console.error("Поиск не выполнен", error instanceof Error ? error.name : "unknown");
    return errorResponse("Поиск не выполнен", 500);
  }

  return jsonResponse({ results: data ?? [], semantic: embedding !== null });
});
