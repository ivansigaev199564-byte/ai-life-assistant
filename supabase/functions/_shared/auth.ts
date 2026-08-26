import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

/// Проверка токена пользователя.
///
/// Функция никогда не работает от имени сервисной роли по запросу
/// с устройства: иначе один пользователь смог бы читать чужие записи,
/// а политики доступа в базе перестали бы что-либо значить. Клиент
/// создаётся с токеном вызывающего, и все запросы идут от его имени.
export interface AuthContext {
  userId: string;
  client: SupabaseClient;
}

export async function authenticate(request: Request): Promise<AuthContext> {
  const authorization = request.headers.get("Authorization");

  if (!authorization) {
    throw new Error("Запрос без токена авторизации");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!supabaseUrl || !anonKey) {
    throw new Error("Функция не сконфигурирована: нет адреса проекта или ключа");
  }

  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  const { data, error } = await client.auth.getUser();

  if (error || !data.user) {
    throw new Error("Токен недействителен");
  }

  return { userId: data.user.id, client };
}
