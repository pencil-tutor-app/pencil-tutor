-- Pencil Tutor: the in-app subscription (App Store auto-renewable, 480 minutes a month). Additive only: two new nullable columns on
-- students, one new table, and indexes. Nothing is dropped, rewritten or backfilled. Every statement is idempotent (if not exists).
-- A subscriber is an ordinary student row (a random code, no name). app_store_original_transaction_id links it to the Apple
-- subscription: the same subscription always maps to the same row, and the unique index is what makes that race-safe.
-- app_store_access_until is the moment the paid period ends (the latest expiry among transactions that were not refunded). A student
-- with an original transaction id and an access time that has passed is treated as turned off. Students without one are untouched.
-- app_store_transactions is the ledger: one row per Apple transaction (each renewal is a new transaction of the same subscription).
-- It makes webhooks and app calls idempotent, and topped_up records that a renewal already refilled the month.

alter table students add column if not exists app_store_original_transaction_id text;

alter table students add column if not exists app_store_access_until timestamptz;

create unique index if not exists students_app_store_original_transaction_key on students (app_store_original_transaction_id) where app_store_original_transaction_id is not null;

create table if not exists app_store_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  student_id bigint not null references students (id) on delete cascade,
  product_id text not null,
  environment text not null,
  purchased_at timestamptz,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  signed_at timestamptz not null,
  topped_up boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists app_store_transactions_original_idx on app_store_transactions (original_transaction_id);

create index if not exists app_store_transactions_student_idx on app_store_transactions (student_id);
