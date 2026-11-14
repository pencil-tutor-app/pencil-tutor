import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { AppStoreGateway, Verified, VerifiedNotification, VerifiedTransaction, VerifyFailure } from "../lib/app-store.js";
import type { Deps } from "../lib/gate.js";
import { handleMe } from "../lib/me.js";
import { handleAppStoreNotification, handlePurchase } from "../lib/purchase.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { isValidCode } from "../lib/students.js";
import { captureLogs, deps, FIXED_NOW, post, reply, TEST_MONTH } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const ENV = {
  APPLE_IAP_PRODUCT_ID: "penciltutor.monthly",
  APPLE_BUNDLE_ID: "com.example.penciltutor",
  APPLE_IAP_ENVIRONMENTS: "sandbox",
};

const DAY = 24 * 3600 * 1000;
const at = (offsetDays: number) => new Date(FIXED_NOW.getTime() + offsetDays * DAY);

// A transaction as Apple would sign it. `signed` is a stand-in string for the JWS the phone sends (the fake gateway maps it).
function transaction(overrides: Partial<VerifiedTransaction> = {}): VerifiedTransaction {
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    productId: "penciltutor.monthly",
    environment: "sandbox",
    purchasedAt: at(0),
    expiresAt: at(30),
    revokedAt: null,
    signedAt: at(0),
    ...overrides,
  };
}

// A fake Apple: it knows the signed strings it was given and answers with what it was told. No keys, no network.
function fakeApple() {
  const transactions = new Map<string, Verified<VerifiedTransaction>>();
  const notifications = new Map<string, Verified<VerifiedNotification>>();
  const gateway: AppStoreGateway = {
    async verifyTransaction(signed) {
      return transactions.get(signed) ?? { ok: false, kind: "invalid", label: "signature_invalid" };
    },
    async verifyNotification(signed) {
      return notifications.get(signed) ?? { ok: false, kind: "invalid", label: "signature_invalid" };
    },
  };
  let n = 0;
  const signedString = (prefix: string) => `${prefix}-${String(++n).padStart(4, "0")}-`.padEnd(80, "x");
  return {
    gateway,
    sends(tx: VerifiedTransaction | VerifyFailure): string {
      const signed = signedString("txn");
      transactions.set(signed, "transactionId" in tx ? { ok: true, value: tx } : tx);
      return signed;
    },
    notifies(type: string, tx: VerifiedTransaction | null, subtype: string | null = null): string {
      const signed = signedString("note");
      notifications.set(signed, { ok: true, value: { type, subtype, uuid: `uuid-${n}`, environment: "sandbox", transaction: tx } });
      return signed;
    },
  };
}

function setup(options: { now?: Date; env?: Record<string, string | undefined> } = {}) {
  const store = new MemoryStudentStore();
  const apple = fakeApple();
  let now = options.now ?? FIXED_NOW;
  store.clock = () => now;
  const d: Deps = { ...deps(options.env ?? ENV, undefined, { store, now: () => now }), appStore: apple.gateway, subscriptions: store };
  return {
    store,
    apple,
    d,
    setNow: (t: Date) => {
      now = t;
    },
    purchase: async (signed: string) => reply(await handlePurchase(post("/api/purchase", { signed_transaction: signed }, null), d)),
    notify: async (signed: string) => reply(await handleAppStoreNotification(post("/api/app-store-notifications", { signedPayload: signed }, null), d)),
    me: async (code: string) =>
      reply(await handleMe(new Request("https://example.test/api/me", { headers: { authorization: `Bearer ${code}` } }), d)),
  };
}

const remainingMinutes = (json: Record<string, unknown>) => (json.allowance as { remaining_minutes: number }).remaining_minutes;

describe("POST /api/purchase", () => {
  it("makes a student for a new subscription and returns a working code with 480 minutes", async () => {
    const t = setup();
    const r = await t.purchase(t.apple.sends(transaction()));
    assert.equal(r.status, 200);
    const code = String(r.json.code);
    assert.ok(isValidCode(code), "a real student code");
    assert.equal(r.json.created, true);
    assert.deepEqual(r.json.plan, { live: false, cap_minutes: 480 });
    assert.equal(remainingMinutes(r.json), 480);
    assert.deepEqual(r.json.subscription, { active: true, expires_at: at(30).toISOString() });

    const asStudent = await t.me(code);
    assert.equal(asStudent.status, 200, "the code works like any other code");
    assert.equal(remainingMinutes(asStudent.json), 480);
  });

  it("gives the same subscription the same code every time, even from a different transaction of it", async () => {
    const t = setup();
    const first = await t.purchase(t.apple.sends(transaction()));
    const again = await t.purchase(t.apple.sends(transaction()));
    const renewal = await t.purchase(t.apple.sends(transaction({ transactionId: "2000000000000009", signedAt: at(1) })));
    assert.equal(again.json.code, first.json.code);
    assert.equal(renewal.json.code, first.json.code);
    assert.deepEqual([first.json.created, again.json.created, renewal.json.created], [true, false, false]);
    const other = await t.purchase(t.apple.sends(transaction({ transactionId: "3", originalTransactionId: "3" })));
    assert.notEqual(other.json.code, first.json.code, "a different subscription is a different student");
  });

  it("two simultaneous reports of the same purchase end with one student", async () => {
    const t = setup();
    const signed = t.apple.sends(transaction());
    const [a, b] = await Promise.all([t.purchase(signed), t.purchase(signed)]);
    assert.equal(a.json.code, b.json.code);
    assert.equal([a.json.created, b.json.created].filter(Boolean).length, 1, "exactly one created it");
  });

  it("does not create a student for a transaction that is already over, and says so", async () => {
    const t = setup();
    const expired = await t.purchase(t.apple.sends(transaction({ expiresAt: at(-1) })));
    assert.deepEqual([expired.status, expired.json.error], [403, "subscription_not_active"]);
    const refunded = await t.purchase(t.apple.sends(transaction({ transactionId: "5", originalTransactionId: "5", revokedAt: at(-1) })));
    assert.deepEqual([refunded.status, refunded.json.error], [403, "subscription_not_active"]);
    assert.equal(await t.store.findStudent("2000000000000001"), null);
    assert.equal(await t.store.findStudent("5"), null);
  });

  it("refuses what Apple's check refuses: 422 for a bad signature, wrong app or wrong product, 503 when the check cannot run", async () => {
    const t = setup();
    const cases: [VerifyFailure, number, string][] = [
      [{ ok: false, kind: "invalid", label: "signature_invalid" }, 422, "invalid_transaction"],
      [{ ok: false, kind: "wrong_app", label: "bundle_id_mismatch" }, 422, "wrong_app"],
      [{ ok: false, kind: "wrong_product", label: "product_not_ours" }, 422, "wrong_product"],
      [{ ok: false, kind: "environment_not_accepted", label: "production_not_accepted" }, 422, "environment_not_accepted"],
      [{ ok: false, kind: "unavailable", label: "apple_check_unavailable" }, 503, "apple_check_unavailable"],
    ];
    for (const [failure, status, error] of cases) {
      const r = await t.purchase(t.apple.sends(failure));
      assert.deepEqual([r.status, r.json.error], [status, error], failure.label);
    }
    assert.equal((await t.purchase("a".repeat(80))).status, 422, "a string Apple never signed");
  });

  it("answers 503 when the in-app purchase settings are missing, naming the setting and no value", async () => {
    const t = setup({ env: { APPLE_BUNDLE_ID: "com.example.penciltutor" } });
    const r = await t.purchase("a".repeat(80));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "iap_not_configured", "APPLE_IAP_PRODUCT_ID is not set"]);
  });

  it("answers 503 when the database is down, and 405 / 422 for a wrong method or body", async () => {
    const t = setup();
    const signed = t.apple.sends(transaction());
    t.store.failWith = new Error("db down");
    const down = await t.purchase(signed);
    assert.deepEqual([down.status, down.json.error], [503, "database_unavailable"]);
    t.store.failWith = null;
    assert.equal((await reply(await handlePurchase(new Request("https://example.test/api/purchase"), t.d))).status, 405);
    assert.equal((await reply(await handlePurchase(post("/api/purchase", { nope: 1 }, null), t.d))).status, 422);
  });
});

describe("subscription lifecycle", () => {
  it("stops the code when the paid period ends, with no notification needed, and starts again on a new period", async () => {
    const t = setup();
    const code = String((await t.purchase(t.apple.sends(transaction()))).json.code);
    assert.equal((await t.me(code)).status, 200);

    t.setNow(at(31));
    const ended = await t.me(code);
    assert.deepEqual([ended.status, ended.json.error, ended.json.reason], [403, "code_disabled", "the subscription behind this code has ended"]);

    t.setNow(at(32));
    const resubscribed = await t.purchase(t.apple.sends(transaction({ transactionId: "77", purchasedAt: at(32), expiresAt: at(62), signedAt: at(32) })));
    assert.equal(resubscribed.json.code, code, "the same subscription keeps the same code");
    assert.equal((await t.me(code)).status, 200);
  });

  // Bought 20 days before the fixed "today" (Oct 25), so the first period ends on Nov 24 and the renewal falls mid-month in November.
  async function boughtTwentyDaysAgo(t: ReturnType<typeof setup>) {
    t.setNow(at(-20));
    const first = await t.purchase(t.apple.sends(transaction({ purchasedAt: at(-20), expiresAt: at(10), signedAt: at(-20) })));
    const student = (await t.store.findStudent("2000000000000001"))!;
    return { code: String(first.json.code), id: student.id };
  }

  it("a renewal notice tops the month back up to 480 minutes, once", async () => {
    const t = setup();
    const { code, id } = await boughtTwentyDaysAgo(t);

    t.setNow(at(5));
    t.store.setUsage(id, TEST_MONTH, { countedSeconds: 400 * 60 });
    assert.equal(remainingMinutes((await t.me(code)).json), 80);

    t.setNow(at(10));
    const renewal = transaction({ transactionId: "2000000000000002", purchasedAt: at(10), expiresAt: at(40), signedAt: at(10) });
    const note = t.apple.notifies("DID_RENEW", renewal);
    assert.deepEqual(await t.notify(note), { status: 200, json: { ok: true, decision: "applied", request_id: logs.lines.at(-1)!.request_id } });
    assert.equal(logs.lines.at(-1)!.top_up, "topped_up");
    assert.equal(remainingMinutes((await t.me(code)).json), 480, "full again");

    // The same renewal arrives again (Apple retries, and the app reports it too): nothing more is given.
    t.store.setUsage(id, TEST_MONTH, { countedSeconds: 400 * 60 + 100 * 60 });
    await t.notify(note);
    const reported = await t.purchase(t.apple.sends(renewal));
    assert.equal(reported.status, 200);
    assert.equal(logs.lines.at(-1)!.top_up, "already_topped_up");
    assert.equal(remainingMinutes((await t.me(code)).json), 380, "100 more minutes used, no second refill");
  });

  it("never lowers time a student already has beyond 480", async () => {
    const t = setup();
    const { code, id } = await boughtTwentyDaysAgo(t);
    t.store.setUsage(id, TEST_MONTH, { countedSeconds: 100 * 60, bonusSeconds: 200 * 60 });
    t.setNow(at(10));
    await t.notify(t.apple.notifies("DID_RENEW", transaction({ transactionId: "2", expiresAt: at(40), signedAt: at(10) })));
    assert.equal(remainingMinutes((await t.me(code)).json), 580, "480 + 200 bonus - 100 used, untouched");
  });

  it("a refund notice stops the code at once, even with days left, and a reversal brings it back", async () => {
    const t = setup();
    const code = String((await t.purchase(t.apple.sends(transaction()))).json.code);

    const refunded = transaction({ revokedAt: at(2), signedAt: at(2) });
    t.setNow(at(3));
    assert.equal((await t.notify(t.apple.notifies("REFUND", refunded))).json.decision, "applied");
    const off = await t.me(code);
    assert.deepEqual([off.status, off.json.error], [403, "code_disabled"]);

    // An older copy of the same transaction arriving late (before the refund was signed) must not undo it.
    await t.notify(t.apple.notifies("DID_RENEW", transaction({ signedAt: at(1) })));
    assert.equal((await t.me(code)).status, 403);

    // Apple reverses the refund: a newer copy with no revocation.
    await t.notify(t.apple.notifies("REFUND_REVERSED", transaction({ signedAt: at(4) })));
    assert.equal((await t.me(code)).status, 200);
  });

  it("an expiry notice about a subscription we never saw changes nothing and makes no student", async () => {
    const t = setup();
    t.setNow(at(40));
    const r = await t.notify(t.apple.notifies("EXPIRED", transaction({ expiresAt: at(30) })));
    assert.deepEqual([r.status, r.json.decision], [200, "ignored_unknown_subscription"]);
    assert.equal(await t.store.findStudent("2000000000000001"), null);
  });

  it("a notice that arrives before the app creates the student, and the app then gets the same code", async () => {
    const t = setup();
    const tx = transaction();
    await t.notify(t.apple.notifies("SUBSCRIBED", tx, "INITIAL_BUY"));
    const viaNotice = await t.store.findStudent(tx.originalTransactionId);
    assert.ok(viaNotice);
    const viaApp = await t.purchase(t.apple.sends(tx));
    assert.equal(viaApp.json.code, viaNotice.code);
    assert.equal(logs.lines.at(-1)!.top_up, "already_topped_up", "the first transaction never refills");
  });

  it("acknowledges notice types that change nothing, and a notice for another product", async () => {
    const t = setup();
    for (const type of ["DID_CHANGE_RENEWAL_STATUS", "DID_FAIL_TO_RENEW", "PRICE_INCREASE", "TEST"]) {
      const r = await t.notify(t.apple.notifies(type, transaction()));
      assert.deepEqual([r.status, r.json.decision], [200, "ignored_type"], type);
    }
    assert.equal(await t.store.findStudent("2000000000000001"), null, "ignored types never create anyone");
    const noTransaction = await t.notify(t.apple.notifies("DID_RENEW", null));
    assert.equal(noTransaction.json.decision, "ignored_no_transaction");
  });

  it("refuses a notice Apple's check refuses, asks Apple to retry when the database is down", async () => {
    const t = setup();
    assert.equal((await t.notify("z".repeat(80))).status, 422);
    const signed = t.apple.notifies("DID_RENEW", transaction());
    t.store.failWith = new Error("db down");
    assert.equal((await t.notify(signed)).status, 503);
  });
});

describe("what the logs say", () => {
  it("records every decision as labels and never the signed string, the code, or an Apple id in clear", async () => {
    const t = setup();
    const signed = t.apple.sends(transaction());
    const r = await t.purchase(signed);
    const code = String(r.json.code);
    await t.notify(t.apple.notifies("DID_RENEW", transaction({ transactionId: "2000000000000002", signedAt: at(1) })));
    await t.purchase(t.apple.sends({ ok: false, kind: "invalid", label: "signature_invalid" }));

    const text = logs.raw.join("\n");
    assert.ok(!text.includes(signed.slice(0, 20)), "the signed transaction is not logged");
    assert.ok(!text.includes(code), "the code is not logged");
    assert.ok(!text.includes("2000000000000001") && !text.includes("2000000000000002"), "Apple ids are hashed");

    const purchaseLine = logs.lines.find((l) => l.endpoint === "purchase" && l.status === 200)!;
    assert.match(String(purchaseLine.student), /^[0-9a-f]{8}$/);
    assert.match(String(purchaseLine.original), /^[0-9a-f]{8}$/);
    assert.deepEqual([purchaseLine.subscription, purchaseLine.top_up, purchaseLine.outcome, purchaseLine.reason], ["created", "new_subscriber", "ok", "subscriber_created"]);
    const notice = logs.lines.find((l) => l.endpoint === "app-store-notifications")!;
    assert.deepEqual([notice.notification_type, notice.decision, notice.top_up], ["DID_RENEW", "applied", "topped_up"]);
    const bad = logs.lines.filter((l) => l.endpoint === "purchase").at(-1)!;
    assert.deepEqual([bad.status, bad.verify_result, bad.reason], [422, "invalid", "signature_invalid"]);
  });
});
