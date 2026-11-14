import { z } from "zod";
import {
  appStoreConfig,
  createAppStoreGateway,
  idHash,
  type AppStoreConfig,
  type AppStoreGateway,
  type VerifyFailure,
} from "./app-store.js";
import { DatabaseError, openDb } from "./db.js";
import { resolveStore, timedDb, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { applyTransaction, PgSubscriptionStore, type SubscriptionStore } from "./subscriptions.js";
import { allowanceOf, codeHash, vancouverMonth } from "./students.js";

// POST /api/purchase and POST /api/app-store-notifications: the in-app subscription (plan amendment 20, docs/app-store.md).
//
// /api/purchase has no student code (the buyer does not have one yet). Its credential is the signed transaction Apple handed the
// phone: the server checks Apple's signature with Apple's own library, then returns the code that belongs to that subscription,
// making it the first time. /api/app-store-notifications is Apple calling us (App Store Server Notifications V2): renewals,
// expiry and refunds, signed the same way. Both end in applyTransaction (lib/subscriptions.ts), which is idempotent.
//
// Logging: ids as short hashes, counts, and reason labels. Never the signed strings, the code in clear, or the Apple ids in clear.

const gateways = new Map<string, AppStoreGateway>();
function gatewayFor(config: AppStoreConfig): AppStoreGateway {
  const key = JSON.stringify(config);
  let gateway = gateways.get(key);
  if (!gateway) {
    gateway = createAppStoreGateway(config);
    gateways.set(key, gateway);
  }
  return gateway;
}

type Ready = { ok: true; config: AppStoreConfig; gateway: AppStoreGateway; subscriptions: SubscriptionStore } | { ok: false; response: Response };

function ready(ctx: RequestCtx, deps: Deps): Ready {
  const parsed = appStoreConfig(deps.env);
  if (!parsed.ok) return { ok: false, response: ctx.fail(503, "iap_not_configured", parsed.reason, "iap_not_configured") };
  let subscriptions = deps.subscriptions;
  if (!subscriptions) {
    const db = openDb(deps.env);
    if (!db) return { ok: false, response: ctx.fail(503, "database_unavailable", "DATABASE_URL is not set", "database_unavailable:DATABASE_URL is not set") };
    subscriptions = new PgSubscriptionStore(db);
  }
  let gateway = deps.appStore;
  if (!gateway) {
    try {
      gateway = gatewayFor(parsed.config);
    } catch {
      return { ok: false, response: ctx.fail(503, "iap_not_configured", "the Apple verifier could not be set up from these settings", "iap_not_configured") };
    }
  }
  ctx.note({ iap_environments: parsed.config.environments.join("+") });
  return { ok: true, config: parsed.config, gateway, subscriptions };
}

const databaseDown = (ctx: RequestCtx, err: unknown) => {
  const label = err instanceof DatabaseError ? err.label : "db_error";
  return ctx.fail(503, "database_unavailable", label, `database_unavailable:${label}`);
};

// A signed payload that was refused, as the reply. "unavailable" is 503 so the caller (the phone, or Apple) tries again.
function refused(ctx: RequestCtx, failure: VerifyFailure): Response {
  const status = failure.kind === "unavailable" ? 503 : 422;
  const error = failure.kind === "unavailable" ? "apple_check_unavailable" : failure.kind === "invalid" ? "invalid_transaction" : failure.kind;
  ctx.note({ verify_result: failure.kind });
  return ctx.fail(status, error, failure.label, `${error}:${failure.label}`);
}

const PurchaseBody = z.object({ signed_transaction: z.string().min(50).max(20_000) });

// ----- POST /api/purchase -----

export async function handlePurchase(request: Request, deps: Deps): Promise<Response> {
  const ctx = new RequestCtx("purchase", request.method);
  if (request.method !== "POST") return ctx.fail(405, "method_not_allowed", "use POST", "method_not_allowed");

  const setup = ready(ctx, deps);
  if (!setup.ok) return setup.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);
  const parsed = PurchaseBody.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", "signed_transaction is required", "invalid_request");

  const verified = await setup.gateway.verifyTransaction(parsed.data.signed_transaction);
  if (!verified.ok) return refused(ctx, verified);
  const tx = verified.value;
  const now = deps.now?.() ?? new Date();
  const month = vancouverMonth(now);
  ctx.note({ original: idHash(tx.originalTransactionId), transaction: idHash(tx.transactionId), iap_environment: tx.environment, verify_result: "ok" });

  // An expired or refunded transaction never makes a student and never hands out a code. If the subscription is already known, the
  // record is still brought up to date (a refund must stick even when the app is the one that reported it).
  const over = tx.revokedAt !== null || tx.expiresAt.getTime() <= now.getTime();
  try {
    const applied = await timedDb(ctx, () =>
      applyTransaction(setup.subscriptions, tx, { createIfMissing: !over, capSeconds: setup.config.monthlySeconds, month, now }),
    );
    if (over || !applied) {
      ctx.note({ subscription: over ? (tx.revokedAt ? "refunded" : "expired") : "unknown" });
      return ctx.fail(403, "subscription_not_active", over ? (tx.revokedAt ? "this purchase was refunded" : "this subscription has ended") : "no such subscription", "subscription_not_active");
    }

    const students = resolveStore(deps);
    if (!students) return ctx.fail(503, "database_unavailable", "DATABASE_URL is not set", "database_unavailable:DATABASE_URL is not set");
    const student = await timedDb(ctx, () => students.lookup(applied.student.code, month));
    if (!student) return ctx.fail(500, "internal", "the new code could not be read back", "student_missing_after_apply");

    ctx.note({
      student: codeHash(applied.student.code),
      subscription: applied.created ? "created" : "existing",
      top_up: applied.topUp,
      access_until: applied.accessUntil.toISOString(),
    });
    if (student.disabled) {
      // Turned off by hand (the subscription itself is active, or we would not be here).
      return ctx.fail(403, "code_disabled", "this code has been turned off", "code_disabled");
    }
    const allowance = allowanceOf(month, student.usage, student.capSeconds);
    ctx.allowance = allowance;
    return ctx.respond(
      200,
      {
        code: applied.student.code,
        created: applied.created,
        plan: { live: student.planLive, cap_minutes: Math.round(student.capSeconds / 60) },
        subscription: { active: true, expires_at: applied.accessUntil.toISOString() },
      },
      "ok",
      applied.created ? "subscriber_created" : "subscriber_existing",
    );
  } catch (err) {
    return databaseDown(ctx, err);
  }
}

// ----- POST /api/app-store-notifications -----

const NotificationBody = z.object({ signedPayload: z.string().min(50).max(60_000) });

// The notification types that carry a transaction we should apply. Everything else is acknowledged and logged as ignored: Apple
// retries any non-200 for days, and none of the others change what a student may do (a failed renewal simply ends at expiry).
const APPLIED_TYPES = new Set(["SUBSCRIBED", "DID_RENEW", "OFFER_REDEEMED", "EXPIRED", "GRACE_PERIOD_EXPIRED", "REFUND", "REVOKE", "REFUND_REVERSED", "RENEWAL_EXTENDED"]);

export async function handleAppStoreNotification(request: Request, deps: Deps): Promise<Response> {
  const ctx = new RequestCtx("app-store-notifications", request.method);
  if (request.method !== "POST") return ctx.fail(405, "method_not_allowed", "use POST", "method_not_allowed");

  const setup = ready(ctx, deps);
  if (!setup.ok) return setup.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);
  const parsed = NotificationBody.safeParse(body.value);
  if (!parsed.success) return ctx.fail(400, "invalid_request", "signedPayload is required", "invalid_request");

  const verified = await setup.gateway.verifyNotification(parsed.data.signedPayload);
  if (!verified.ok) return refused(ctx, verified);
  const note = verified.value;
  const now = deps.now?.() ?? new Date();
  ctx.note({
    notification_type: note.type,
    notification_subtype: note.subtype ?? "none",
    notification: idHash(note.uuid),
    iap_environment: note.environment,
    verify_result: "ok",
  });

  if (!APPLIED_TYPES.has(note.type)) {
    ctx.note({ decision: "ignored_type" });
    return ctx.respond(200, { ok: true, decision: "ignored_type" }, "ok", `ignored:${note.type}`);
  }
  if (!note.transaction) {
    ctx.note({ decision: "ignored_no_transaction_for_our_product" });
    return ctx.respond(200, { ok: true, decision: "ignored_no_transaction" }, "ok", "ignored:no_transaction");
  }

  const tx = note.transaction;
  ctx.note({ original: idHash(tx.originalTransactionId), transaction: idHash(tx.transactionId) });
  const over = tx.revokedAt !== null || tx.expiresAt.getTime() <= now.getTime();
  try {
    const applied = await timedDb(ctx, () =>
      applyTransaction(setup.subscriptions, tx, {
        // Only a live, paid transaction may make a student. Expiry and refund notices about a subscription we never saw change nothing.
        createIfMissing: !over,
        capSeconds: setup.config.monthlySeconds,
        month: vancouverMonth(now),
        now,
      }),
    );
    if (!applied) {
      ctx.note({ decision: "ignored_unknown_subscription" });
      return ctx.respond(200, { ok: true, decision: "ignored_unknown_subscription" }, "ok", "ignored:unknown_subscription");
    }
    ctx.note({
      decision: "applied",
      student: codeHash(applied.student.code),
      subscription: applied.created ? "created" : "existing",
      access_active: applied.active,
      access_until: applied.accessUntil.toISOString(),
      top_up: applied.topUp,
    });
    return ctx.respond(200, { ok: true, decision: "applied" }, "ok", `applied:${note.type}`);
  } catch (err) {
    // 503 so Apple delivers it again later.
    return databaseDown(ctx, err);
  }
}
