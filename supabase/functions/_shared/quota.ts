import type { AuthContext } from "./auth.ts";

/// Пределы расхода на пользователя за сутки.
///
/// Числа взяты с запасом относительно живого использования: человек,
/// диктующий по десятку заметок в день, их не заметит. Заметит тот, кто
/// решит прогнать через чужой ключ пару тысяч запросов за ночь.
export const DAILY_LIMITS = {
  parse: 300,
  embed: 200,
  search: 500,
} as const;

export type QuotaKind = keyof typeof DAILY_LIMITS;

export class QuotaExceededError extends Error {
  constructor(kind: QuotaKind) {
    super(`Дневной предел обращений исчерпан (${kind})`);
    this.name = "QuotaExceededError";
  }
}

/// Списывает одно обращение и бросает исключение при превышении.
///
/// Счётчик увеличивается в базе одним запросом, поэтому параллельные вызовы
/// не могут проскочить мимо предела: гонка решается на уровне строки.
export async function consumeQuota(context: AuthContext, kind: QuotaKind): Promise<void> {
  const { data, error } = await context.client.rpc("consume_quota", {
    quota_kind: kind,
    daily_limit: DAILY_LIMITS[kind],
  });

  if (error) {
    // Счётчик недоступен: это не повод пускать запрос дальше, иначе предел
    // обходится простым способом сломать таблицу.
    console.error("Счётчик расхода недоступен", error.code ?? "unknown");
    throw new QuotaExceededError(kind);
  }

  if (data === false) {
    throw new QuotaExceededError(kind);
  }
}
