-- Пределы расхода и проверка владельца в связях.
--
-- Регистрация в приложении свободная: вход через Apple открыт любому Apple ID,
-- а адрес проекта и анонимный ключ лежат в бинарнике. Без предела на человека
-- тысяча параллельных запросов к разбору превращается в чужой счёт за модель.

-- MARK: Расход на пользователя

create table if not exists usage_counters (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null,
  -- Сутки в UTC: сдвиг относительно местного времени пользователя здесь
  -- не важен, важно, что окно закрывается.
  window_date date not null default (now() at time zone 'utc')::date,
  calls integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, window_date)
);

alter table usage_counters enable row level security;

drop policy if exists owner_read on usage_counters;
create policy owner_read on usage_counters
  for select
  using (user_id = (select auth.uid()));

-- Писать в счётчик может только функция ниже: она объявлена security definer,
-- то есть пользователь не может обнулить свой расход сам.

comment on table usage_counters is 'Счётчик обращений к платным функциям за сутки';

-- MARK: Списание квоты

create or replace function consume_quota(quota_kind text, daily_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  used integer;
begin
  if current_user_id is null then
    return false;
  end if;

  insert into usage_counters as counters (user_id, kind, calls)
  values (current_user_id, quota_kind, 1)
  on conflict (user_id, kind, window_date)
    do update set
      calls = counters.calls + 1,
      updated_at = now()
  returning calls into used;

  return used <= daily_limit;
end;
$$;

revoke all on function consume_quota(text, integer) from public;
grant execute on function consume_quota(text, integer) to authenticated;

comment on function consume_quota is
  'Увеличивает счётчик обращений и отвечает, уложился ли пользователь в предел';

-- MARK: Векторы принадлежат пользователю

-- Глобальная уникальность по (entity_id, entity_type) позволяла занять чужой
-- идентификатор сущности: первый, кто вставил строку, владел ключом навсегда.
alter table embeddings drop constraint if exists embeddings_entity_id_entity_type_key;

create unique index if not exists embeddings_owner_entity_key
  on embeddings (user_id, entity_id, entity_type);

-- MARK: Связи только со своими сущностями

-- Политика владельца проверяла только user_id самой связи, поэтому в неё
-- можно было положить чужой person_id или project_id.
drop policy if exists owner_all on entity_people;
create policy owner_all on entity_people
  for all
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from people
      where people.id = entity_people.person_id
        and people.user_id = (select auth.uid())
    )
  );

drop policy if exists owner_all on entity_projects;
create policy owner_all on entity_projects
  for all
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from projects
      where projects.id = entity_projects.project_id
        and projects.user_id = (select auth.uid())
    )
  );
