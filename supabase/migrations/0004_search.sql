-- Полнотекстовый поиск.
--
-- Поисковый вектор хранится в самой строке и пересчитывается базой:
-- считать его в приложении значит однажды забыть обновить после правки.

alter table captures
  add column if not exists search_vector tsvector
  generated always as (
    to_tsvector('russian_unaccent', coalesce(text, ''))
  ) stored;

alter table notes
  add column if not exists search_vector tsvector
  generated always as (
    to_tsvector('russian_unaccent', coalesce(title, '') || ' ' || coalesce(body, ''))
  ) stored;

alter table tasks
  add column if not exists search_vector tsvector
  generated always as (
    to_tsvector('russian_unaccent', coalesce(title, '') || ' ' || coalesce(details, ''))
  ) stored;

alter table reminders
  add column if not exists search_vector tsvector
  generated always as (
    to_tsvector('russian_unaccent', coalesce(title, '') || ' ' || coalesce(details, ''))
  ) stored;

alter table expenses
  add column if not exists search_vector tsvector
  generated always as (
    to_tsvector('russian_unaccent', coalesce(details, '') || ' ' || coalesce(merchant, ''))
  ) stored;

create index if not exists captures_search_idx on captures using gin (search_vector);
create index if not exists notes_search_idx on notes using gin (search_vector);
create index if not exists tasks_search_idx on tasks using gin (search_vector);
create index if not exists reminders_search_idx on reminders using gin (search_vector);
create index if not exists expenses_search_idx on expenses using gin (search_vector);

-- Триграммный индекс для опечаток распознавания: «Скуратов» может
-- приехать как «Скураттов», и точный поиск такое не найдёт.
create index if not exists captures_text_trgm_idx on captures using gin (text gin_trgm_ops);
create index if not exists people_name_trgm_idx on people using gin (name gin_trgm_ops);

-- Индексы под синхронизацию: клиент запрашивает всё, что изменилось
-- после его последней отметки времени.
create index if not exists captures_sync_idx on captures (user_id, updated_at desc);
create index if not exists notes_sync_idx on notes (user_id, updated_at desc);
create index if not exists tasks_sync_idx on tasks (user_id, updated_at desc);
create index if not exists reminders_sync_idx on reminders (user_id, updated_at desc);
create index if not exists expenses_sync_idx on expenses (user_id, updated_at desc);
create index if not exists people_sync_idx on people (user_id, updated_at desc);
create index if not exists projects_sync_idx on projects (user_id, updated_at desc);

-- Частые выборки: незакрытые дела и траты за период.
create index if not exists tasks_open_idx on tasks (user_id, is_completed, due_date);
create index if not exists reminders_upcoming_idx on reminders (user_id, is_completed, fire_date);
create index if not exists expenses_period_idx on expenses (user_id, spent_at desc);
