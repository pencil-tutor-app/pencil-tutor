-- Pencil Tutor: student codes and monthly usage. Additive only: new tables and indexes, nothing dropped or rewritten.
-- Each statement is idempotent (if not exists), so running the migration twice is safe.
-- No student names live here: a student is a random code and a number. Edward keeps the code-to-student list offline.

create table if not exists schema_migrations (
  name text primary key,
  applied_at timestamptz not null default now()
);

create table if not exists students (
  id bigint generated always as identity primary key,
  code text not null,
  monthly_cap_seconds integer not null default 28800,
  plan_live boolean not null default false,
  disabled_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists students_code_key on students (code);

-- One row per student per month. The month is the first day of the month in America/Vancouver.
-- counted_seconds is the running total (never recounted); covered_until is where the recent-activity window currently ends.
create table if not exists usage_months (
  student_id bigint not null references students (id) on delete cascade,
  month date not null,
  counted_seconds integer not null default 0,
  covered_until timestamptz,
  bonus_seconds integer not null default 0,
  tts_chars integer not null default 0,
  tts_chars_eleven integer not null default 0,
  tts_utterances integer not null default 0,
  looks integer not null default 0,
  questions integer not null default 0,
  low_notice_at timestamptz,
  used_up_notice_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (student_id, month)
);
