-- Правки синхронизации: время и версия принадлежат базе, а не устройству.

-- MARK: Время вставки

-- Триггер версии висел только на update, поэтому при вставке в базу попадали
-- updated_at и version с часов телефона. Часы уходят вперёд на минуты,
-- и второе устройство эти записи не запрашивало: их время оказывалось
-- «в будущем» относительно курсора.
create or replace function bump_version()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.updated_at := now();
    new.version := 1;
  else
    new.updated_at := now();
    new.version := coalesce(old.version, 0) + 1;
  end if;
  return new;
end;
$$;

do $$
declare
  target text;
begin
  foreach target in array array[
    'captures', 'notes', 'tasks', 'reminders', 'expenses', 'people', 'projects'
  ]
  loop
    execute format('drop trigger if exists %I_bump_version on %I', target, target);
    execute format(
      'create trigger %I_bump_version before insert or update on %I
         for each row execute function bump_version()',
      target, target
    );
  end loop;
end;
$$;

-- MARK: Владелец по умолчанию

-- Страховка на случай, если клиент забудет подставить идентификатор:
-- лучше запись, принадлежащая вошедшему пользователю, чем отказ вставки.
do $$
declare
  target text;
begin
  foreach target in array array[
    'captures', 'notes', 'tasks', 'reminders', 'expenses', 'people', 'projects',
    'entity_people', 'entity_projects'
  ]
  loop
    execute format('alter table %I alter column user_id set default auth.uid()', target);
  end loop;
end;
$$;

-- MARK: Выборка изменений

-- Клиент забирает изменения страницами по updated_at: без индекса каждая
-- страница это последовательное чтение таблицы.
create index if not exists captures_owner_updated_idx on captures (user_id, updated_at);
create index if not exists notes_owner_updated_idx on notes (user_id, updated_at);
create index if not exists tasks_owner_updated_idx on tasks (user_id, updated_at);
create index if not exists reminders_owner_updated_idx on reminders (user_id, updated_at);
create index if not exists expenses_owner_updated_idx on expenses (user_id, updated_at);
create index if not exists people_owner_updated_idx on people (user_id, updated_at);
create index if not exists projects_owner_updated_idx on projects (user_id, updated_at);
