-- Pencil Tutor: opt-in student memory, phase 1 (docs/tutor-memory-plan.md). Additive only: new tables and indexes, nothing
-- dropped or rewritten. Every statement is idempotent (if not exists), so running the migration twice is safe.
-- Nothing here is filled for a student unless a parent or guardian (or an adult student) has agreed: the server checks the
-- latest consent_events row before it writes anything. No names, pictures, audio, transcripts or hint text are stored.

-- Append-only. The latest row for a student is the current state: a grant, or a withdrawal.
create table if not exists consent_events (
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  granted boolean not null,
  given_by text check (given_by in ('parent_guardian', 'adult_student')),
  recorded_via text not null check (recorded_via in ('app', 'admin')),
  notice_version text not null,
  notice_hash text,
  evidence_on date,
  at timestamptz not null default now()
);
create index if not exists consent_events_latest on consent_events (student_id, id desc);

-- Edward's notes after a human session. Written only by his admin tool, never by an app endpoint.
create table if not exists human_note (
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  session_on date not null,
  body text not null check (char_length(body) between 1 and 500),
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists human_note_pick on human_note (student_id, pinned desc, session_on desc, id desc);

-- One row per (student, app session, problem). A session id is made fresh for each opening of a problem screen.
create table if not exists attempt (
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  session_id text not null,
  problem_id text not null,
  looks integer not null default 0,
  asks integer not null default 0,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  unique (student_id, session_id, problem_id)
);
create index if not exists attempt_recent on attempt (student_id, last_at desc);

-- One row per interrupt the server decided on. No hint text. Unique, so a retried request adds nothing.
create table if not exists hint_event (
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  attempt_id bigint not null references attempt (id) on delete cascade,
  line integer not null,
  drawing_revision integer not null,
  at timestamptz not null default now(),
  unique (attempt_id, drawing_revision, line)
);
create index if not exists hint_event_student on hint_event (student_id, at desc);
