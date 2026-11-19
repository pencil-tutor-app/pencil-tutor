-- Pencil Tutor: free codes (docs/free-launch-plan.md). Additive only: one new column with a constant default on students, two new
-- tables, one index. Nothing is dropped, rewritten or backfilled. Every statement is idempotent (if not exists), so running it twice is safe.
-- Run `scripts/codes migrate` BEFORE deploying the server that reads students.origin.

-- Where a code came from: 'admin' is every code Edward made with scripts/codes (and every code that existed before this migration),
-- 'free' is a code the app asked the server for. A constant default makes this a metadata-only change in Postgres 11 and later.
alter table students add column if not exists origin text not null default 'admin' constraint students_origin_known check (origin in ('admin', 'free'));

-- The running estimated cost of all free codes together, one row per month (the first day of the month in America/Vancouver).
-- spent_micros is millionths of a US dollar, so adding never drifts. It is bumped by an atomic upsert before and after each paid
-- call made for a free code (reserve, then settle) and is never recounted from other rows. eleven_chars is information only:
-- ElevenLabs is a flat plan, so it adds no dollars, but its characters come out of a shared monthly pool. calls counts reservations.
create table if not exists free_spend_months (
  month date primary key,
  spent_micros bigint not null default 0 constraint free_spend_never_negative check (spent_micros >= 0),
  eleven_chars bigint not null default 0,
  calls bigint not null default 0,
  updated_at timestamptz not null default now()
);

-- The per-address limit on making free codes. ip_hash is a keyed hash of the network address (never the address itself), stamps are
-- the times of the most recent creations inside the rolling 24 hours (at most the limit, so the row stays tiny). No student id is
-- kept next to a hash. Rows not touched for 2 days are deleted by the server and by scripts/codes free-spend.
create table if not exists free_code_ip_limits (
  ip_hash text primary key,
  stamps timestamptz[] not null,
  updated_at timestamptz not null default now()
);

create index if not exists free_code_ip_limits_updated on free_code_ip_limits (updated_at);
