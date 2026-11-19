import type { Env } from "./config.js";
import { DatabaseError } from "./db.js";
import { ceilingOf, countText, microsToUsd, type Counted, type Reserve } from "./free-config.js";
import { timedDb, type GateOpen } from "./gate.js";
import type { RequestCtx } from "./http.js";
import { logLine } from "./log.js";
import type { UsageReport } from "./usage.js";

// The spending meter for free codes (docs/free-launch-plan.md). Every paid call made for a free code goes through `paidCall`:
//   1. RESERVE the worst case this call can cost, atomically, unless that would push the month's total past the ceiling (then the
//      call is refused with 403 free_tutoring_full and nothing is spent). Parallel calls therefore cannot overshoot the ceiling
//      by more than an actual cost above its own reserve.
//   2. RUN the call.
//   3. SETTLE: replace the reserve with what the call is counted at (see countText and friends in free-config.ts). Anything uncertain
//      (a failure, a timeout, no usage in the reply) keeps its reserve counted: the meter errs on the side of closing early.
// For a code that is not free this is just `run()`: no reserve, no price lookup, no database call, nothing refused.
//
// The total is an ESTIMATE from the price tables in pricing.ts, not the provider's invoice. ElevenLabs is a flat plan already
// paid, so it adds 0 dollars; its characters are only recorded (recordElevenChars) because they come out of a shared monthly pool.

export type PaidCall<T> = {
  kind: string; // a short label for the log: "watch", "ask", "consult", "reword", "speech_fallback"
  reserve: () => Reserve | undefined; // called only for a free code; undefined means the model has no price, so no bound
  run: () => Promise<T>;
  count: (result: T, reserve: Reserve) => Counted;
};
// Why a paid call was not made. A handler that owns the request turns it into the reply with `refuse`; the reword step, which
// belongs to a request that carries on without it, only logs the label.
export type Refusal = { status: 403 | 503; error: string; reason: string; outcome: string };
export type PaidResult<T> = { ok: true; value: T } | { ok: false; refusal: Refusal };

export const refuse = (ctx: RequestCtx, r: Refusal): Response => ctx.fail(r.status, r.error, r.reason, r.outcome);

const FULL_REASON = "free tutoring is full this month, it comes back on the 1st";

const dbLabel = (err: unknown): string => (err instanceof DatabaseError ? err.label : "db_error");

// What a text model's result is counted at: a failure keeps the whole reserve, a reply with usage is counted at its estimate, a reply
// without usage keeps one attempt's bound. Works for the watch, ask, consult and reword results alike.
export const countModelResult = (result: { kind: string; usage?: UsageReport; label?: string }, reserve: Reserve): Counted =>
  result.kind === "failed" ? countText(undefined, result.label ?? "failed", reserve) : countText(result.usage, null, reserve);

export async function paidCall<T>(ctx: RequestCtx, env: Env, opened: GateOpen, call: PaidCall<T>): Promise<PaidResult<T>> {
  if (opened.student.origin !== "free") return { ok: true, value: await call.run() };

  const { store, month } = opened;
  const student = ctx.fields.student as string;
  const reserve = call.reserve();
  if (!reserve) {
    // No price means no bound on what the call can cost, so a free code does not get it.
    return { ok: false, refusal: { status: 503, error: "bad_config", reason: "free_model_unpriced", outcome: `free_model_unpriced:${call.kind}` } };
  }
  const ceiling = ceilingOf(env);

  let totalAfterReserve: number | null;
  try {
    totalAfterReserve = await timedDb(ctx, () => store.reserveFreeSpend(month, reserve.total, ceiling.micros));
  } catch (err) {
    // Fail closed: no money is spent for a free code unless the meter could be written.
    const label = dbLabel(err);
    return { ok: false, refusal: { status: 503, error: "database_unavailable", reason: label, outcome: `database_unavailable:${label}` } };
  }
  if (totalAfterReserve === null) {
    ctx.note({ [`free_${call.kind}_reserve_usd`]: microsToUsd(reserve.total) });
    return { ok: false, refusal: { status: 403, error: "free_tutoring_full", reason: FULL_REASON, outcome: `free_tutoring_full:${call.kind}_reserve_refused` } };
  }

  let value: T;
  let counted: Counted;
  try {
    value = await call.run();
    counted = call.count(value, reserve);
  } catch (err) {
    // The call threw instead of returning a failure: it may have been billed, so the whole reserve stays counted.
    await settle(ctx, store, month, call.kind, reserve, { micros: reserve.total, basis: "reserve_kept_failed", detail: `threw_${err instanceof Error ? err.name : "error"}` }, totalAfterReserve, ceiling.micros, student);
    throw err;
  }
  await settle(ctx, store, month, call.kind, reserve, counted, totalAfterReserve, ceiling.micros, student);
  return { ok: true, value };
}

async function settle(
  ctx: RequestCtx,
  store: GateOpen["store"],
  month: string,
  kind: string,
  reserve: Reserve,
  counted: Counted,
  totalAfterReserve: number,
  ceilingMicros: number,
  student: string,
): Promise<void> {
  try {
    const total = await timedDb(ctx, () => store.settleFreeSpend(month, counted.micros - reserve.total, 0));
    ctx.note({
      [`free_${kind}_reserved_usd`]: microsToUsd(reserve.total),
      [`free_${kind}_counted_usd`]: microsToUsd(counted.micros),
      [`free_${kind}_basis`]: counted.detail ? `${counted.basis}:${counted.detail}` : counted.basis,
      free_month_usd: microsToUsd(total),
    });
    // One warning line the moment the month's total crosses the ceiling, so the day it closed is easy to find.
    if (totalAfterReserve - reserve.total < ceilingMicros && total >= ceilingMicros) {
      logLine("warn", { endpoint: ctx.endpoint, request_id: ctx.id, outcome: "free_ceiling_reached", reason: `after_${kind}`, free_month_usd: microsToUsd(total), free_ceiling_usd: microsToUsd(ceilingMicros) });
    }
  } catch (err) {
    // The reserve stays in the total, which is at least the cost for a call within its bound: it over-counts, never under-counts.
    logLine("error", {
      request_id: ctx.id,
      endpoint: ctx.endpoint,
      student,
      outcome: "free_spend_not_recorded",
      reason: dbLabel(err),
      kind,
      reserved_usd: microsToUsd(reserve.total),
      would_count_usd: microsToUsd(counted.micros),
    });
  }
}

// The characters ElevenLabs spoke for a free code. Adds no dollars (flat plan). Never stops the audio; a failure is logged.
export async function recordElevenChars(ctx: RequestCtx, opened: GateOpen, chars: number): Promise<void> {
  if (opened.student.origin !== "free") return;
  try {
    const total = await timedDb(ctx, () => opened.store.settleFreeSpend(opened.month, 0, chars));
    ctx.note({ free_eleven_chars: chars, free_month_usd: microsToUsd(total) });
  } catch (err) {
    logLine("error", { request_id: ctx.id, endpoint: ctx.endpoint, student: ctx.fields.student as string, outcome: "free_eleven_chars_not_recorded", reason: dbLabel(err), chars });
  }
}
