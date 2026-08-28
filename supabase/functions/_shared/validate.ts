/// Проверка тела запроса.
///
/// Раньше проверялась только длина текста, а списки известных людей
/// и проектов уходили в промпт как есть. Клиент мог прислать двести тысяч
/// строк по килобайту, пройти проверку и заставить сервер отправить модели
/// сотни мегабайт: это и денежная атака, и способ подменить инструкции.
export const LIMITS = {
  text: 4000,
  listCount: 100,
  listItem: 64,
  currencyCode: 8,
  timeZone: 64,
  languageCode: 16,
} as const;

export class ValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ValidationError";
  }
}

/// Строка допустимой длины или ошибка.
export function requireString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string") {
    throw new ValidationError(`Поле ${field} должно быть строкой`);
  }

  const trimmed = value.trim();
  if (!trimmed) {
    throw new ValidationError(`Поле ${field} пустое`);
  }
  if (trimmed.length > maxLength) {
    throw new ValidationError(`Поле ${field} длиннее допустимого предела`);
  }

  return trimmed;
}

/// Необязательная строка: пустая и отсутствующая равнозначны.
export function optionalString(
  value: unknown,
  field: string,
  maxLength: number,
): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requireString(value, field, maxLength);
}

/// Список строк с ограничением и по числу элементов, и по каждому из них.
///
/// Лишнее не отвергается, а обрезается: список известных людей это подсказка,
/// и потерять её хвост менее обидно, чем получить отказ на всю запись.
export function boundedList(value: unknown, field: string): string[] {
  if (value === undefined || value === null) return [];

  if (!Array.isArray(value)) {
    throw new ValidationError(`Поле ${field} должно быть списком`);
  }

  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim().slice(0, LIMITS.listItem))
    .filter((item) => item.length > 0)
    .slice(0, LIMITS.listCount);
}
