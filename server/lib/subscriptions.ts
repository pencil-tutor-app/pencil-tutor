import type { Db } from "./db.js";
import { generateCode } from "./students.js";
import type { VerifiedTransaction } from "./app-store.js";

// The in-app subscription's records and the rules for turning an Apple transaction into a student's access. See docs/app-store.md
// and plan amendment 20. All SQL for it is here (through lib/db.ts, like every other query); the schema is db/migrations/003.
//
// The model: one Apple subscription (its originalTransactionId) is one student row, so the same subscription always gets the same
// code. Each Apple transaction (the purchase, then one per renewal) is a row in app_store_transactions, which makes every call
// idempotent. Access lasts until the latest expiry among transactions that were not refunded; the gate reads that from the
// student row (see LOOKUP_SQL in students.ts), so expiry and refunds stop a code even if no webhook ever arrives.

export type Subscriber = { id: string; code: string };

export interface SubscriptionStore {
  readonly kind: "postgres" | "memory";
  // The student for this Apple subscription, or null when we have never seen it.
  findStudent(originalTransactionId: string): Promise<Subscriber | null>;
  // The student for this Apple subscription, made if it does not exist yet. Two simultaneous calls get the same student:
  // exactly one of them sees created = true.
  claimStudent(originalTransactionId: string, capSeconds: number): Promise<Subscriber & { created: boolean }>;
  // Writes this transaction into the ledger (a newer copy of a known transaction replaces the older one; an older copy is ignored).
  // `toppedUp` is the value for a brand new row; the stored value is returned.
  recordTransaction(tx: VerifiedTransaction, studentId: string, toppedUp: boolean): Promise<{ toppedUp: boolean }>;
  // Recomputes the end of the paid period (latest expiry among transactions not refunded; the epoch when none) and returns it.
  settleAccess(originalTransactionId: string): Promise<Date>;
  // Raises this month's bonus so the student has at least their full monthly time again. Never lowers anything. Returns the totals.
  topUpMonth(studentId: string, month: string): Promise<{ countedSeconds: number; bonusSeconds: number } | null>;
  markToppedUp(transactionId: string): Promise<void>;
}

// ----- The rules -----

export type TopUpReason = "new_subscriber" | "topped_up" | "already_topped_up" | "not_current" | "no_usage_to_refill";

export type Applied = {
  student: Subscriber;
  created: boolean;
  accessUntil: Date;
  active: boolean;
  topUp: TopUpReason;
};

// Applies one verified transaction. `createIfMissing` is false when the transaction is already known to be over (expired or refunded)
// and must not make a new student. Returns null when it did nothing because the subscription is unknown and may not be created.
// Safe to repeat and safe to run twice at once (the Apple webhook and the app both report the same renewal).
export async function applyTransaction(
  store: SubscriptionStore,
  tx: VerifiedTransaction,
  options: { createIfMissing: boolean; capSeconds: number; month: string; now: Date },
): Promise<Applied | null> {
  let student: Subscriber & { created: boolean };
  if (options.createIfMissing) {
    student = await store.claimStudent(tx.originalTransactionId, options.capSeconds);
  } else {
    const found = await store.findStudent(tx.originalTransactionId);
    if (!found) return null;
    student = { ...found, created: false };
  }

  // A brand new subscriber starts the month full anyway, so their first transaction is recorded as already topped up.
  const recorded = await store.recordTransaction(tx, student.id, student.created);
  const accessUntil = await store.settleAccess(tx.originalTransactionId);
  const active = accessUntil.getTime() > options.now.getTime();

  let topUp: TopUpReason;
  if (student.created) topUp = "new_subscriber";
  else if (recorded.toppedUp) topUp = "already_topped_up";
  else if (tx.revokedAt || tx.expiresAt.getTime() <= options.now.getTime()) topUp = "not_current";
  else {
    // The renewal is new and current: refill this month. Refilling twice in a row changes nothing (it is relative to the time used),
    // so a webhook and an app call racing each other cannot give extra time.
    const totals = await store.topUpMonth(student.id, options.month);
    await store.markToppedUp(tx.transactionId);
    topUp = totals ? "topped_up" : "no_usage_to_refill";
  }
  return { student: { id: student.id, code: student.code }, created: student.created, accessUntil, active, topUp };
}

// ----- Postgres -----

const FIND_SQL = `select id, code from students where app_store_original_transaction_id = $1`;

// `on conflict do nothing` with no target covers both unique indexes: the code (a random collision, try another) and the Apple
// subscription (somebody else claimed it first, read theirs).
const CLAIM_SQL = `
insert into students (code, monthly_cap_seconds, plan_live, app_store_original_transaction_id)
values ($1, $2::int, false, $3)
on conflict do nothing
returning id, code`;

const RECORD_SQL = `
insert into app_store_transactions as t
  (transaction_id, original_transaction_id, student_id, product_id, environment, purchased_at, expires_at, revoked_at, signed_at, topped_up)
values ($1, $2, $3::bigint, $4, $5, $6::timestamptz, $7::timestamptz, $8::timestamptz, $9::timestamptz, $10::boolean)
on conflict (transaction_id) do update set
  expires_at = case when excluded.signed_at > t.signed_at then excluded.expires_at else t.expires_at end,
  revoked_at = case when excluded.signed_at > t.signed_at then excluded.revoked_at else t.revoked_at end,
  signed_at = greatest(t.signed_at, excluded.signed_at)
returning topped_up`;

const SETTLE_SQL = `
update students set app_store_access_until = coalesce(
  (select max(expires_at) from app_store_transactions where original_transaction_id = $1 and revoked_at is null),
  'epoch'::timestamptz)
where app_store_original_transaction_id = $1
returning app_store_access_until`;

// Relative to the time used, so repeating it changes nothing. The 80% and 100% notices are re-armed the same way the admin
// top-up does it (students-admin.ts), so the student hears them again if they run out again.
const TOP_UP_SQL = `
update usage_months u set
  bonus_seconds = greatest(u.bonus_seconds, u.counted_seconds),
  used_up_notice_at = null,
  low_notice_at = case when u.counted_seconds < 0.8 * (s.monthly_cap_seconds + greatest(u.bonus_seconds, u.counted_seconds)) then null else u.low_notice_at end,
  updated_at = now()
from students s
where s.id = u.student_id and u.student_id = $1::bigint and u.month = $2::date
returning u.counted_seconds, u.bonus_seconds`;

const MARK_SQL = `update app_store_transactions set topped_up = true where transaction_id = $1`;

export class PgSubscriptionStore implements SubscriptionStore {
  readonly kind = "postgres" as const;
  constructor(private readonly db: Db) {}

  async findStudent(originalTransactionId: string): Promise<Subscriber | null> {
    const row = (await this.db.query(FIND_SQL, [originalTransactionId]))[0];
    return row ? { id: String(row.id), code: String(row.code) } : null;
  }

  async claimStudent(originalTransactionId: string, capSeconds: number): Promise<Subscriber & { created: boolean }> {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const made = (await this.db.query(CLAIM_SQL, [generateCode(), capSeconds, originalTransactionId]))[0];
      if (made) return { id: String(made.id), code: String(made.code), created: true };
      const existing = await this.findStudent(originalTransactionId);
      if (existing) return { ...existing, created: false };
      // Neither: the random code collided with another student's. Try a new one.
    }
    throw new Error("could not find an unused code after 8 tries");
  }

  async recordTransaction(tx: VerifiedTransaction, studentId: string, toppedUp: boolean): Promise<{ toppedUp: boolean }> {
    const rows = await this.db.query(RECORD_SQL, [
      tx.transactionId,
      tx.originalTransactionId,
      studentId,
      tx.productId,
      tx.environment,
      tx.purchasedAt ? tx.purchasedAt.toISOString() : null,
      tx.expiresAt.toISOString(),
      tx.revokedAt ? tx.revokedAt.toISOString() : null,
      tx.signedAt.toISOString(),
      toppedUp,
    ]);
    return { toppedUp: Boolean(rows[0]?.topped_up) };
  }

  async settleAccess(originalTransactionId: string): Promise<Date> {
    const rows = await this.db.query(SETTLE_SQL, [originalTransactionId]);
    const until = rows[0]?.app_store_access_until;
    if (!until) return new Date(0);
    return until instanceof Date ? until : new Date(String(until));
  }

  async topUpMonth(studentId: string, month: string): Promise<{ countedSeconds: number; bonusSeconds: number } | null> {
    const row = (await this.db.query(TOP_UP_SQL, [studentId, month]))[0];
    return row ? { countedSeconds: Number(row.counted_seconds), bonusSeconds: Number(row.bonus_seconds) } : null;
  }

  async markToppedUp(transactionId: string): Promise<void> {
    await this.db.query(MARK_SQL, [transactionId]);
  }
}
