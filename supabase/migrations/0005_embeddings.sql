-- Смысловой поиск и объединение с полнотекстовым.
--
-- Векторы вынесены в отдельную таблицу, а не в колонку каждой сущности:
-- эмбеддинг считается асинхронно и может отсутствовать, а держать
-- пустую колонку на 1536 чисел в каждой таблице расточительно.

create table if not exists embeddings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,

  entity_id uuid not null,
  entity_type text not null check (
    entity_type in ('capture', 'note', 'task', 'reminder', 'expense')
  ),

  -- Размерность text-embedding-3-small. При смене модели понадобится
  -- новая колонка и пересчёт: сравнивать векторы разных моделей нельзя.
  embedding vector(1536) not null,

  -- Текст, из которого посчитан вектор. Нужен, чтобы понять,
  -- устарел ли эмбеддинг после правки записи.
  source_text text not null,
  model text not null default 'text-embedding-3-small',
  created_at timestamptz not null default now(),

  unique (entity_id, entity_type)
);

alter table embeddings enable row level security;

drop policy if exists owner_all on embeddings;
create policy owner_all on embeddings
  for all
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- HNSW вместо IVFFlat: он не требует обучения на заполненной таблице
-- и работает с первого дня, когда записей ещё десятки.
create index if not exists embeddings_vector_idx
  on embeddings using hnsw (embedding vector_cosine_ops);

create index if not exists embeddings_entity_idx on embeddings (user_id, entity_type);

-- Гибридный поиск.
--
-- Полнотекстовый поиск точен на дословных совпадениях, но не найдёт
-- «потратил на еду» по запросу «сколько ушло на обеды». Векторный
-- наоборот: понимает смысл, но путается на редких словах и именах.
-- Объединяем оба через обратный ранг: позиция важнее абсолютной оценки,
-- потому что шкалы у методов несопоставимы.
create or replace function hybrid_search(
  query_text text,
  query_embedding vector(1536) default null,
  match_count integer default 20,
  full_text_weight double precision default 1.0,
  semantic_weight double precision default 1.0,
  rrf_k integer default 50
)
returns table (
  entity_id uuid,
  entity_type text,
  title text,
  snippet text,
  occurred_at timestamptz,
  score double precision
)
language sql
stable
as $$
  with
  -- Собираем все типы записей в один поток, чтобы искать разом по всему.
  corpus as (
    select
      c.id as entity_id,
      'capture'::text as entity_type,
      left(c.text, 80) as title,
      c.text as snippet,
      c.created_at as occurred_at,
      c.search_vector,
      c.user_id
    from captures c
    where c.deleted_at is null

    union all
    select n.id, 'note', coalesce(nullif(n.title, ''), left(n.body, 80)),
           n.body, n.created_at, n.search_vector, n.user_id
    from notes n
    where n.deleted_at is null

    union all
    select t.id, 'task', t.title, t.details, t.created_at, t.search_vector, t.user_id
    from tasks t
    where t.deleted_at is null

    union all
    select r.id, 'reminder', r.title, r.details, r.fire_date, r.search_vector, r.user_id
    from reminders r
    where r.deleted_at is null

    union all
    select e.id, 'expense',
           coalesce(nullif(e.details, ''), e.category),
           coalesce(e.merchant, '') || ' ' || e.amount::text || ' ' || e.currency_code,
           e.spent_at, e.search_vector, e.user_id
    from expenses e
    where e.deleted_at is null
  ),

  full_text as (
    select
      corpus.entity_id,
      corpus.entity_type,
      row_number() over (
        order by ts_rank_cd(corpus.search_vector, websearch_to_tsquery('russian_unaccent', query_text)) desc
      ) as rank
    from corpus
    where corpus.user_id = (select auth.uid())
      and query_text is not null
      and query_text <> ''
      and corpus.search_vector @@ websearch_to_tsquery('russian_unaccent', query_text)
    limit least(match_count * 3, 100)
  ),

  semantic as (
    select
      embeddings.entity_id,
      embeddings.entity_type,
      row_number() over (
        order by embeddings.embedding <=> query_embedding
      ) as rank
    from embeddings
    where embeddings.user_id = (select auth.uid())
      and query_embedding is not null
    limit least(match_count * 3, 100)
  ),

  merged as (
    select
      coalesce(full_text.entity_id, semantic.entity_id) as entity_id,
      coalesce(full_text.entity_type, semantic.entity_type) as entity_type,
      coalesce(full_text_weight / (rrf_k + full_text.rank), 0)
        + coalesce(semantic_weight / (rrf_k + semantic.rank), 0) as score
    from full_text
    full outer join semantic
      on full_text.entity_id = semantic.entity_id
     and full_text.entity_type = semantic.entity_type
  )

  select
    merged.entity_id,
    merged.entity_type,
    corpus.title,
    left(corpus.snippet, 200) as snippet,
    corpus.occurred_at,
    merged.score
  from merged
  join corpus
    on corpus.entity_id = merged.entity_id
   and corpus.entity_type = merged.entity_type
  order by merged.score desc
  limit match_count;
$$;

-- Записи без эмбеддинга: по этому списку функция генерации векторов
-- понимает, что досчитать.
create or replace function pending_embeddings(limit_count integer default 50)
returns table (entity_id uuid, entity_type text, source_text text)
language sql
stable
as $$
  select c.id, 'capture'::text, c.text
  from captures c
  left join embeddings e
    on e.entity_id = c.id and e.entity_type = 'capture'
  where c.user_id = (select auth.uid())
    and c.deleted_at is null
    and c.text <> ''
    and (e.id is null or e.source_text is distinct from c.text)
  limit limit_count;
$$;
