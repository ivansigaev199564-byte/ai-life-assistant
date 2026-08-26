-- Разграничение доступа.
--
-- Личный дневник голосом это самые чувствительные данные, какие бывают:
-- траты, планы, имена. Поэтому политика одна и без исключений: строку
-- видит только тот, кто её создал. Проверка живёт в базе, а не в коде
-- приложения, и обойти её нельзя даже с валидным токеном другого пользователя.

alter table captures enable row level security;
alter table people enable row level security;
alter table projects enable row level security;
alter table notes enable row level security;
alter table tasks enable row level security;
alter table reminders enable row level security;
alter table expenses enable row level security;
alter table entity_people enable row level security;
alter table entity_projects enable row level security;

-- Одинаковая политика на все таблицы: владелец делает всё, остальные ничего.
do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'captures', 'people', 'projects', 'notes', 'tasks',
    'reminders', 'expenses', 'entity_people', 'entity_projects'
  ]
  loop
    execute format('drop policy if exists owner_all on %I', table_name);
    execute format($policy$
      create policy owner_all on %I
        for all
        to authenticated
        using (user_id = (select auth.uid()))
        with check (user_id = (select auth.uid()))
    $policy$, table_name);
  end loop;
end
$$;

-- Версия и время изменения проставляются базой, а не клиентом:
-- часы на устройстве могут отставать или уходить вперёд, и тогда
-- разрешение конфликтов начнёт выбирать неверную копию.
create or replace function bump_version()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  new.version := coalesce(old.version, 0) + 1;
  return new;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'captures', 'people', 'projects', 'notes', 'tasks', 'reminders', 'expenses'
  ]
  loop
    execute format('drop trigger if exists set_version on %I', table_name);
    execute format(
      'create trigger set_version before update on %I
         for each row execute function bump_version()',
      table_name
    );
  end loop;
end
$$;
