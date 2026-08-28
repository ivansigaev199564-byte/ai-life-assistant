/// Заголовки для preflight-запросов.
///
/// Приложение ходит с устройства, а не из браузера, но Supabase шлёт
/// OPTIONS перед POST, и без ответа на него запрос не доходит.
/// Заголовки для предварительных запросов браузера.
///
/// Источник берётся из переменной окружения: нативному клиенту CORS
/// не нужен вовсе, а звёздочка разрешала обращаться к функциям из любой
/// страницы в интернете. Пусто по умолчанию, то есть браузеры не пускаются.
const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "";

export const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}
