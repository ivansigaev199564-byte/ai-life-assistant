-- Схема данных. Повторяет модели SwiftData, но с серверными дополнениями:
-- владелец строки, версия для разрешения конфликтов и мягкое удаление.
--
-- Идентификаторы приходят с устройства: запись создаётся офлайн и должна
-- сохранить свой id после синхронизации, иначе связи между сущностями
-- порвутся, а повторная отправка создаст дубли.

-- Мягкое удаление вместо физического: устройство, которое было офлайн,
-- обязано узнать, что запись удалена, а не воскресить её при следующей
-- синхронизации.

create table if not exists captures (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,

  text text not null default '',
  source text not null default 'inApp',
  status text not null default 'pending',
  engine text not null default 'none',
  language_code text,

  recognition_confidence double precision not null default 0,
  parse_confidence double precision not null default 0,
  parsing_engine text,
  audio_duration double precision not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  parsed_at timestamptz,
  deleted_at timestamptz,

  -- Версия растёт при каждом изменении: по ней клиент понимает,
  -- что серверная копия новее локальной.
  version bigint not null default 1
);

create table if not exists people (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,

  name text not null,
  normalized_name text not null,
  aliases text[] not null default '{}',
  contact_identifier text,
  mention_count integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table if not exists projects (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,

  name text not null,
  normalized_name text not null,
  aliases text[] not null default '{}',
  details text not null default '',
  color_hex text not null default '#2F6BFF',
  is_archived boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table if not exists notes (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  capture_id uuid references captures (id) on delete cascade,
  parsed_item_id uuid,

  title text not null default '',
  body text not null default '',
  tags text[] not null default '{}',
  confidence double precision not null default 1,
  needs_review boolean not null default false,
  is_archived boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table if not exists tasks (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  capture_id uuid references captures (id) on delete cascade,
  parsed_item_id uuid,

  title text not null,
  details text not null default '',
  due_date timestamptz,
  priority text not null default 'none',
  is_completed boolean not null default false,
  completed_at timestamptz,
  external_reminder_id text,
  confidence double precision not null default 1,
  needs_review boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table if not exists reminders (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  capture_id uuid references captures (id) on delete cascade,
  parsed_item_id uuid,

  title text not null,
  details text not null default '',
  fire_date timestamptz not null,
  recurrence_rule text,
  priority text not null default 'none',
  is_completed boolean not null default false,
  completed_at timestamptz,
  external_identifier text,
  confidence double precision not null default 1,
  needs_review boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table if not exists expenses (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  capture_id uuid references captures (id) on delete cascade,
  parsed_item_id uuid,

  -- numeric, а не double precision: деньги на плавающей точке округляются
  -- неверно, и сумма расходов за месяц не сойдётся с суммой чеков.
  amount numeric(14, 2) not null,
  currency_code text not null default 'RUB',
  category text not null default 'other',
  details text not null default '',
  merchant text,
  spent_at timestamptz not null default now(),
  confidence double precision not null default 1,
  needs_review boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

-- Связи многие ко многим: человек и проект упоминаются сразу в нескольких
-- записях разных типов.
create table if not exists entity_people (
  entity_id uuid not null,
  entity_type text not null check (entity_type in ('note', 'task', 'reminder', 'expense')),
  person_id uuid not null references people (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  primary key (entity_id, entity_type, person_id)
);

create table if not exists entity_projects (
  entity_id uuid not null,
  entity_type text not null check (entity_type in ('note', 'task', 'reminder', 'expense')),
  project_id uuid not null references projects (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  primary key (entity_id, entity_type, project_id)
);
