import type { Env } from "../config.js";
import { DatabaseError, openDb } from "../db.js";
import type { WatchResult } from "../decision.js";
import { countText, maxOutputTokensOf, textReserve } from "../free-config.js";
import { paidCall } from "../free-spend.js";
import { configForLevel, type Deps, type GateOpen } from "../gate.js";
import type { RequestCtx } from "../http.js";
import { logLine } from "../log.js";
import { levelOf, type Problem } from "../problems.js";
import { usageFields } from "../usage.js";
import { NOTICE_VERSION } from "./notice.js";
import { rewordSpoken } from "./reword.js";
import { PgRecordStore, type RecordStore } from "./store.js";

// Glue between the request handlers and the record. Every function here fails closed and quiet for the student: a problem with
// the record is logged with a label and the request carries on exactly as it would without memory.

// New memory activity (recording, notes, a new grant) happens only when STUDENT_RECORD=on. Managing an existing record
// (status, withdraw, erase) never depends on it, see lib/record/endpoint.ts.
export const recordSwitchedOn = (env: Env): boolean => env.STUDENT_RECORD === "on";
export const rewordSwitchedOn = (env: Env): boolean => recordSwitchedOn(env) && env.STUDENT_RECORD_REWORD === "on";

export function recordFor(deps: Deps): RecordStore | undefined {
  if (!recordSwitchedOn(deps.env)) return undefined;
  if (deps.record) return deps.record;
  const db = openDb(deps.env);
  return db ? new PgRecordStore(db) : undefined;
}

// The record store for managing a record, whatever the switch says.
export function managementStore(deps: Deps): RecordStore | undefined {
  if (deps.record) return deps.record;
  const db = openDb(deps.env);
  return db ? new PgRecordStore(db) : undefined;
}

const failLabel = (err: unknown): string => (err instanceof DatabaseError ? err.label : "db_error");

// After the watch call has decided: records the look (and the hint event) for a student who has consented, and for an interrupt
// may reword the spoken hint with Edward's notes. Returns the result to send, which differs from the input only in `hint_spoken`.
export async function afterLook(
  ctx: RequestCtx,
  deps: Deps,
  opened: GateOpen,
  args: { sessionId: string | undefined; problem: Problem; revision: number; result: WatchResult },
): Promise<WatchResult> {
  const record = recordFor(deps);
  if (!record) return args.result;
  const { result } = args;
  const interrupted = result.action === "interrupt" && result.line !== null;
  const reword = rewordSwitchedOn(deps.env) && !opened.scripted && interrupted;
  const started = Date.now();
  let notes: Awaited<ReturnType<RecordStore["recordLook"]>>["notes"] = [];
  try {
    const out = await record.recordLook(opened.student.id, NOTICE_VERSION, {
      sessionId: args.sessionId ?? "",
      problemId: args.problem.id,
      interrupt: interrupted ? { line: result.line as number, revision: args.revision } : null,
      wantNotes: reword,
    });
    notes = out.notes;
    ctx.note({ memory_write: out.consented ? "ok" : "skipped:no_consent", memory_write_ms: Date.now() - started, memory_notes: notes.length });
  } catch (err) {
    ctx.note({ memory_write: `failed:${failLabel(err)}`, memory_write_ms: Date.now() - started });
    return result;
  }
  if (!reword || notes.length === 0 || !result.hint_spoken) return result;

  const picked = configForLevel(ctx, opened, deps.env, "watch", levelOf(args.problem));
  if (!picked.ok) {
    ctx.note({ reword: "fallback:no_model_config" });
    return result;
  }
  // For a free code this second model call is bounded and metered like the first (lib/free-spend.ts); one attempt, no retry.
  const cap = maxOutputTokensOf(deps.env);
  const paid = await paidCall(ctx, deps.env, opened, {
    kind: "reword",
    reserve: () => textReserve(picked.cfg.model, opened.now, cap, 1),
    run: () =>
      rewordSpoken({
        model: deps.models.language(picked.cfg, picked.key),
        cfg: picked.cfg,
        problem: args.problem,
        line: result.line as number,
        spoken: result.hint_spoken as string,
        notes,
        maxOutputTokens: opened.student.origin === "free" ? cap : undefined,
      }),
    count: (done, reserve) => (done.usage ? countText(done.usage, null, reserve) : countText(undefined, done.ok ? null : done.reason, reserve)),
  });
  if (!paid.ok) {
    // The ordinary hint is spoken instead; the request carries on, so this is a label, not an error reply.
    ctx.note({ reword: `fallback:${paid.refusal.outcome}` });
    return result;
  }
  const out = paid.value;
  // The second call's tokens and cost, kept apart from the watch call's fields on the same log line.
  const second = usageFields(out.usage);
  ctx.note({ reword_model_ms: second.model_ms, reword_input_tokens: second.input_tokens, reword_output_tokens: second.output_tokens, reword_est_cost_usd: second.est_cost_usd });
  if (!out.ok) {
    ctx.note({ reword: `fallback:${out.reason}` });
    return result;
  }
  ctx.note({ reword: "used" });
  return { ...result, hint_spoken: out.text };
}

// A spoken question (ask or consult): one counter, for a student who has consented.
export async function afterQuestion(ctx: RequestCtx, deps: Deps, opened: GateOpen, args: { sessionId: string | undefined; problemId: string }): Promise<void> {
  const record = recordFor(deps);
  if (!record) return;
  const started = Date.now();
  try {
    const consented = await record.recordQuestion(opened.student.id, NOTICE_VERSION, { sessionId: args.sessionId ?? "", problemId: args.problemId });
    ctx.note({ memory_write: consented ? "ok" : "skipped:no_consent", memory_write_ms: Date.now() - started });
  } catch (err) {
    ctx.note({ memory_write: `failed:${failLabel(err)}`, memory_write_ms: Date.now() - started });
  }
}

// One line for each change of a person's choice, so the record of who agreed is also in the logs. Labels and counts only.
export function logConsentChange(ctx: RequestCtx, event: "memory_consent_granted" | "memory_withdrawn" | "memory_erased", fields: Record<string, string | number | boolean>): void {
  logLine("info", { request_id: ctx.id, endpoint: ctx.endpoint, student: ctx.fields.student as string, event, ...fields });
}
