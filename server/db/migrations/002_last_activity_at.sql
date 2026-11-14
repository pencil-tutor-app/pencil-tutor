-- Pencil Tutor: the "counted time is real working time" rule (2026-11-14). Additive only: one new nullable column, nothing
-- dropped, rewritten or backfilled. Idempotent (if not exists), so running it twice is safe.
-- last_activity_at is the time of the last counted activity moment (ink, a question, a look, live voice talk). The next moment is
-- charged the gap since it, when the gap is 60 seconds or less. covered_until (the old forward 2-minute window) stays in the
-- table, unused, and is not read or written by the server any more. Existing rows start with NULL, so each student's next
-- activity is a "first activity" and charges 0; no month's running total changes.

alter table usage_months add column if not exists last_activity_at timestamptz;
