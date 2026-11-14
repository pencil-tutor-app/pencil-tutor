import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import type { VerifiedTransaction } from "../lib/app-store.js";
import type { Db } from "../lib/db.js";
import { splitStatements } from "../lib/students-admin.js";
import { applyTransaction, PgSubscriptionStore } from "../lib/subscriptions.js";
import { isValidCode, PgStudentStore } from "../lib/students.js";

// Runs the real SQL of the in-app subscription (migration 003, lib/subscriptions.ts, the lookup in lib/students.ts) on PGlite, which
// is Postgres compiled to WebAssembly and lives inside this test process: no server, no Docker, nothing installed. It is meant for
// GitHub CI, which sets CI=true. On a laptop it is skipped unless PT_PGLITE=1 (the laptop stays light; run the other tests there).
// The production Neon database is never touched.
const enabled = process.env.CI === "true" || process.env.PT_PGLITE === "1";

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");
const MONTH = "2026-11-01";
const day = (n: number) => new Date(Date.UTC(2026, 10, 14, 18) + n * 24 * 3600 * 1000);

function tx(overrides: Partial<VerifiedTransaction> = {}): VerifiedTransaction {
  return {
    transactionId: "1001",
    originalTransactionId: "1001",
    productId: "penciltutor.monthly",
    environment: "sandbox",
    purchasedAt: day(0),
    expiresAt: day(30),
    revokedAt: null,
    signedAt: day(0),
    ...overrides,
  };
}

describe("subscription SQL on Postgres (PGlite)", { skip: !enabled }, () => {
  let pg: PGlite;
  let db: Db;
  let subs: PgSubscriptionStore;
  let students: PgStudentStore;

  before(async () => {
    pg = new PGlite();
    db = { query: async (text, params) => (await pg.query(text, params as unknown[] | undefined)).rows as Record<string, unknown>[] };
    subs = new PgSubscriptionStore(db);
    students = new PgStudentStore(db);
    for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
      for (const statement of splitStatements(readFileSync(join(MIGRATIONS, file), "utf8"))) await db.query(statement);
    }
    // The migrations are written to be run twice without harm.
    for (const statement of splitStatements(readFileSync(join(MIGRATIONS, "003_app_store_subscriptions.sql"), "utf8"))) await db.query(statement);
  });

  after(async () => {
    await pg.close();
  });

  it("gives one Apple subscription one student, even when two claims race", async () => {
    const [a, b] = await Promise.all([subs.claimStudent("2001", 28_800), subs.claimStudent("2001", 28_800)]);
    assert.equal(a.id, b.id);
    assert.equal(a.code, b.code);
    assert.deepEqual([a.created, b.created].sort(), [false, true]);
    assert.ok(isValidCode(a.code));
    assert.deepEqual(await subs.findStudent("2001"), { id: a.id, code: a.code });
    assert.equal(await subs.findStudent("nope"), null);
    const rows = await db.query("select monthly_cap_seconds, plan_live from students where app_store_original_transaction_id = '2001'");
    assert.deepEqual(rows.map((r) => [Number(r.monthly_cap_seconds), r.plan_live]), [[28_800, false]]);
  });

  it("keeps students without a subscription out of the new rule", async () => {
    await db.query("insert into students (code) values ('AAAAAAAA')");
    const found = await students.lookup("AAAAAAAA", MONTH);
    assert.deepEqual([found?.disabled, found?.subscriptionEnded], [false, false]);
  });

  it("ends a subscriber's code until the first transaction is recorded, then opens it for the paid period", async () => {
    const student = await subs.claimStudent("3001", 28_800);
    assert.equal((await students.lookup(student.code, MONTH))?.disabled, true, "no access time yet counts as ended (the safe side)");

    const applied = await applyTransaction(subs, tx({ transactionId: "3001", originalTransactionId: "3001", expiresAt: new Date(Date.now() + 5 * 24 * 3600 * 1000) }), {
      createIfMissing: true,
      capSeconds: 28_800,
      month: MONTH,
      now: new Date(),
    });
    assert.ok(applied);
    assert.deepEqual([applied.created, applied.active, applied.topUp], [false, true, "no_usage_to_refill"]);
    const found = await students.lookup(student.code, MONTH);
    assert.deepEqual([found?.disabled, found?.subscriptionEnded], [false, false]);

    await db.query("update students set app_store_access_until = now() - interval '1 second' where code = $1", [student.code]);
    assert.deepEqual([(await students.lookup(student.code, MONTH))?.disabled, (await students.lookup(student.code, MONTH))?.subscriptionEnded], [true, true]);
  });

  it("records a transaction once, lets a newer copy replace an older one and ignores an older copy", async () => {
    const student = await subs.claimStudent("4001", 28_800);
    assert.deepEqual(await subs.recordTransaction(tx({ transactionId: "4001", originalTransactionId: "4001" }), student.id, true), { toppedUp: true });
    assert.deepEqual(await subs.recordTransaction(tx({ transactionId: "4001", originalTransactionId: "4001" }), student.id, false), { toppedUp: true }, "the stored value wins");

    await subs.recordTransaction(tx({ transactionId: "4001", originalTransactionId: "4001", revokedAt: day(2), signedAt: day(2) }), student.id, false);
    assert.equal((await subs.settleAccess("4001")).getTime(), 0, "refunded: no paid time left (the epoch)");

    await subs.recordTransaction(tx({ transactionId: "4001", originalTransactionId: "4001", signedAt: day(1) }), student.id, false);
    assert.equal((await subs.settleAccess("4001")).getTime(), 0, "an older, unrefunded copy arriving late does not undo it");

    await subs.recordTransaction(tx({ transactionId: "4001", originalTransactionId: "4001", signedAt: day(3) }), student.id, false);
    assert.equal((await subs.settleAccess("4001")).toISOString(), day(30).toISOString(), "a newer copy (refund reversed) restores it");

    await subs.recordTransaction(tx({ transactionId: "4002", originalTransactionId: "4001", expiresAt: day(60), signedAt: day(30) }), student.id, false);
    assert.equal((await subs.settleAccess("4001")).toISOString(), day(60).toISOString(), "access runs to the latest expiry");
  });

  it("tops the month up to the full allowance without ever lowering it or doing it twice", async () => {
    const student = await subs.claimStudent("5001", 28_800);
    assert.equal(await subs.topUpMonth(student.id, MONTH), null, "no usage this month: nothing to refill");

    await db.query("insert into usage_months (student_id, month, counted_seconds, bonus_seconds, low_notice_at, used_up_notice_at) values ($1::bigint, $2::date, 30000, 0, now(), now())", [student.id, MONTH]);
    const first = await subs.topUpMonth(student.id, MONTH);
    assert.deepEqual(first, { countedSeconds: 30_000, bonusSeconds: 30_000 });
    const record = await students.lookup(student.code, MONTH);
    assert.deepEqual([record?.usage.bonusSeconds, record?.usage.usedUpNoticed, record?.usage.lowNoticed], [30_000, false, false], "notices re-armed (30000 of 58800 is under 80%)");

    assert.deepEqual(await subs.topUpMonth(student.id, MONTH), first, "repeating changes nothing");

    await db.query("update usage_months set bonus_seconds = 40000 where student_id = $1::bigint", [student.id]);
    assert.equal((await subs.topUpMonth(student.id, MONTH))?.bonusSeconds, 40_000, "never lowered");
  });

  it("a renewal through applyTransaction refills once and a repeat of the same renewal does not", async () => {
    const now = day(10);
    const bought = await applyTransaction(subs, tx({ transactionId: "6001", originalTransactionId: "6001", purchasedAt: day(-20), expiresAt: day(10), signedAt: day(-20) }), {
      createIfMissing: true,
      capSeconds: 28_800,
      month: MONTH,
      now: day(-20),
    });
    assert.ok(bought);
    assert.equal(bought.topUp, "new_subscriber");
    await db.query("insert into usage_months (student_id, month, counted_seconds) values ($1::bigint, $2::date, 24000)", [bought.student.id, MONTH]);

    const renewal = tx({ transactionId: "6002", originalTransactionId: "6001", purchasedAt: day(10), expiresAt: day(40), signedAt: day(10) });
    const options = { createIfMissing: true, capSeconds: 28_800, month: MONTH, now };
    assert.equal((await applyTransaction(subs, renewal, options))?.topUp, "topped_up");
    await db.query("update usage_months set counted_seconds = 30000 where student_id = $1::bigint", [bought.student.id]);
    assert.equal((await applyTransaction(subs, renewal, options))?.topUp, "already_topped_up");
    const record = await students.lookup(bought.student.code, MONTH);
    assert.equal(record?.usage.bonusSeconds, 24_000, "the repeat added nothing");

    const lapsed = await applyTransaction(subs, tx({ transactionId: "9", originalTransactionId: "never-seen", expiresAt: day(-1) }), { ...options, createIfMissing: false });
    assert.equal(lapsed, null, "an over transaction of an unknown subscription makes nobody");
  });

  it("deleting a student removes their ledger rows", async () => {
    const student = await subs.claimStudent("7001", 28_800);
    await subs.recordTransaction(tx({ transactionId: "7001", originalTransactionId: "7001" }), student.id, true);
    await db.query("delete from students where id = $1::bigint", [student.id]);
    assert.equal((await db.query("select 1 from app_store_transactions where transaction_id = '7001'")).length, 0);
  });
});
