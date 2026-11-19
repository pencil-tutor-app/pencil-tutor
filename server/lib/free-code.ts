import { DatabaseError } from "./db.js";
import {
  ceilingOf,
  clientAddress,
  freeIsFull,
  hashAddress,
  microsToUsd,
  perIpLimit,
  saltOf,
  STALE_IP_ROW_MS,
} from "./free-config.js";
import { defaultDeps, resolveStore, timedDb, type Deps } from "./gate.js";
import { RequestCtx } from "./http.js";
import { logLine } from "./log.js";
import { allowanceOf, codeHash, DEFAULT_MONTHLY_CAP_SECONDS, EMPTY_USAGE, generateCode, vancouverMonth, type SlotClaim } from "./students.js";

// POST /api/free-code: "Start free". The app asks for a new code, gets one with 8 hours a month (the same meter and caps as any
// code), live voice off, and signs in with it. No code is needed to call it, so it is guarded three ways (docs/free-launch-plan.md):
//   1. at most FREE_CODE_PER_IP_PER_DAY (3) codes per network address per rolling 24 hours; only a keyed hash of the address is
//      stored, and creation is refused outright while FREE_CODE_IP_SALT is not set;
//   2. nothing is made while all free codes together have reached the month's spending ceiling;
//   3. (phase 2, not built) App Attest, see APP_ATTEST_SEAM below.
// Logging: the line for a made code carries the code's log id and never the address hash; a refused line carries the address hash
// and no code. So no log line links an address to a code.

const MAX_INSERT_TRIES = 8;

// A database error that is the server saying NO to a statement (an SQLSTATE such as db_23505) means the statement did not happen.
// A timeout or a network error (db_timeout, db_error_*) means we do not know whether it did.
const knownFailure = (err: unknown): boolean => err instanceof DatabaseError && /^db_[0-9a-z]{5}$/.test(err.label);
const labelOf = (err: unknown): string => (err instanceof DatabaseError ? err.label : "db_error");

export async function handleFreeCode(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("free-code", request.method);
  const { env } = deps;

  if (request.method !== "POST") return ctx.fail(405, "method_not_allowed", "use POST", "method_not_allowed");

  // Safe failure: with no secret salt the address hash would be easy to reverse (there are only 2^32 IPv4 addresses), and without
  // the rate limit the endpoint is an open tap. So no salt means no free codes, and the reason is in the reply and the log.
  const salt = saltOf(env);
  if (!salt.ok) return ctx.fail(503, "free_codes_unavailable", salt.reason, `free_codes_unavailable:${salt.reason}`);

  const store = resolveStore(deps);
  if (!store) return ctx.fail(503, "database_unavailable", "DATABASE_URL is not set", "database_unavailable:DATABASE_URL is not set");

  const now = deps.now?.() ?? new Date();
  const month = vancouverMonth(now);
  const ceiling = ceilingOf(env);
  if (ceiling.source === "invalid_env_using_default") {
    logLine("warn", { request_id: ctx.id, endpoint: "free-code", outcome: "free_setting_ignored", reason: "FREE_MONTHLY_CEILING_USD is not a number of 0 or more; using the default" });
  }

  // 1. The ceiling comes first, so a full month never burns anybody's address slot.
  let spent: number;
  try {
    spent = await timedDb(ctx, () => store.freeSpentMicros(month));
  } catch (err) {
    return ctx.fail(503, "database_unavailable", labelOf(err), `database_unavailable:${labelOf(err)}`);
  }
  ctx.note({ free_spent_usd: microsToUsd(spent), free_ceiling_usd: ceiling.usd });
  if (freeIsFull(spent, ceiling.micros)) {
    return ctx.fail(403, "free_tutoring_full", "free tutoring is full this month, it comes back on the 1st", "free_code_refused:ceiling_reached");
  }

  // 2. The address. Vercel puts the client's address in these headers (lib/free-config.ts, clientAddress).
  const address = clientAddress(request.headers);
  if (!address) return ctx.fail(400, "bad_request", "no_client_ip", "free_code_refused:no_client_ip");

  // APP_ATTEST_SEAM (phase 2, after Edward buys the Apple Developer account; not built, nothing here depends on it): the app proves
  // it is the real app on a real Apple device (DeviceCheck App Attest) and the server refuses the request here when it cannot
  // verify that. It goes HERE: after the ceiling check, before the address slot is taken, so a rejected device burns no slot.
  // The plan is in docs/free-launch-plan.md, "Phase 2: App Attest".

  // 3. The address slot: one atomic statement. A refusal writes nothing, so hammering the endpoint does not extend a lock-out.
  const ipHash = hashAddress(address, salt.salt);
  const limit = perIpLimit(env).limit;
  let claim: SlotClaim;
  try {
    claim = await timedDb(ctx, () => store.claimFreeCodeSlot(ipHash, now, limit));
  } catch (err) {
    return ctx.fail(503, "database_unavailable", labelOf(err), `database_unavailable:${labelOf(err)}`);
  }
  if (!claim.allowed) {
    // The only line that carries the address hash (8 of its 32 characters), and no code exists on it.
    ctx.note({ ip_hash: ipHash.slice(0, 8), ip_limit: limit, retry_after_seconds: claim.retryAfterSeconds });
    return ctx.fail(429, "rate_limited", "ip_limit_reached", "free_code_refused:ip_limit_reached", { "retry-after": String(claim.retryAfterSeconds) });
  }

  // 4. Make the code. Up to 8 draws, because a collision is possible in principle (30^8 codes).
  let code: string | null = null;
  try {
    for (let attempt = 0; attempt < MAX_INSERT_TRIES && code === null; attempt += 1) {
      const candidate = generateCode();
      if (await timedDb(ctx, () => store.createFreeStudent(candidate, DEFAULT_MONTHLY_CAP_SECONDS))) code = candidate;
    }
  } catch (err) {
    return await abandon(ctx, store, ipHash, now, err);
  }
  if (code === null) return await abandon(ctx, store, ipHash, now, new DatabaseError("db_no_unused_code"), true);

  // 5. Housekeeping: address hashes nobody has touched for 2 days are useless (the window is 24 hours). Best effort, never fatal.
  try {
    const purged = await timedDb(ctx, () => store.purgeStaleFreeCodeSlots(new Date(now.getTime() - STALE_IP_ROW_MS)));
    ctx.note({ ip_rows_purged: purged });
  } catch (err) {
    ctx.note({ ip_rows_purged: `failed:${labelOf(err)}` });
  }

  const allowance = allowanceOf(month, EMPTY_USAGE, DEFAULT_MONTHLY_CAP_SECONDS);
  // `student` is the same short log id `codes list` prints, so a support question about a code can be found in the logs.
  ctx.note({ student: codeHash(code), origin: "free", ip_slot: `${claim.used}/${limit}`, cap_minutes: Math.round(allowance.cap_seconds / 60) });
  return ctx.respond(200, { code, cap_minutes: Math.round(allowance.cap_seconds / 60) }, "ok", "free_code_created");
}

// The creation failed after the slot was taken. If the database KNOWS it failed, give the slot back; if it is unsure (a timeout, a
// network error) the code may exist, so the slot stays used and the log says so.
async function abandon(
  ctx: RequestCtx,
  store: NonNullable<ReturnType<typeof resolveStore>>,
  ipHash: string,
  at: Date,
  err: unknown,
  definitelyFailed = false,
): Promise<Response> {
  const label = labelOf(err);
  if (definitelyFailed || knownFailure(err)) {
    try {
      await timedDb(ctx, () => store.releaseFreeCodeSlot(ipHash, at));
      ctx.note({ slot: "released" });
    } catch (releaseErr) {
      ctx.note({ slot: `release_failed:${labelOf(releaseErr)}` });
    }
    return ctx.fail(503, "free_codes_unavailable", label, `free_code_insert_failed:${label}`);
  }
  ctx.note({ slot: "kept_outcome_unknown" });
  return ctx.fail(503, "free_codes_unavailable", label, `free_code_insert_outcome_unknown:${label}`);
}
