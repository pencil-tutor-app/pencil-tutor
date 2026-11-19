import { z } from "zod";
import {
  apiKeyFor,
  ConfigError,
  DEFAULT_LEVEL,
  missingKeyReason,
  roleConfig,
  scriptedState,
  type Env,
  type Level,
  type Role,
  type RoleConfig,
} from "./config.js";
import { DatabaseError, openDb } from "./db.js";
import { ceilingOf, freeIsFull, microsToUsd } from "./free-config.js";
import { RequestCtx, readBearerCode } from "./http.js";
import { logLine } from "./log.js";
import type { LiveGateway } from "./live.js";
import type { RecordStore } from "./record/store.js";
import { realModels, type ModelFactory } from "./models.js";
import {
  allowanceOf,
  codeHash,
  PgStudentStore,
  vancouverMonth,
  type ActivityKind,
  type StudentRecord,
  type StudentStore,
} from "./students.js";
import type { VoiceGateway } from "./voice.js";

// `live` is the one place the server talks to OpenAI's Live endpoint; tests pass a fake. Unset means the real one.
// `students` is where codes and usage live (Postgres on Neon); tests pass an in-memory one. `voice` is the ElevenLabs call.
export type Deps = {
  env: Env;
  models: ModelFactory;
  live?: LiveGateway;
  students?: StudentStore;
  voice?: VoiceGateway;
  // The opt-in student record (lib/record). Unset means the real one when STUDENT_RECORD=on, otherwise none.
  record?: RecordStore;
  now?: () => Date;
};
export const defaultDeps = (): Deps => ({ env: process.env, models: realModels });

export type GateOptions = {
  method?: "POST" | "GET";
  // GPT-Live is reachable only when the student's plan has live: true.
  requireLive?: boolean;
  // Out-of-hours students are refused unless the endpoint is one of the fixed allowance notices.
  allowOverCap?: boolean;
  // A free code is refused everywhere that costs money once all free codes together have reached the monthly ceiling, the fixed
  // allowance notices included (the app then speaks on the device voice). Only /api/me (so the banner can clear on the 1st) and
  // /api/memory (a family can always withdraw or erase) set this.
  skipFreeCeiling?: boolean;
};

export type GateOpen = {
  ok: true;
  scripted: boolean;
  configs: Partial<Record<Role, RoleConfig>>;
  keys: Partial<Record<Role, string>>;
  student: StudentRecord;
  store: StudentStore;
  code: string;
  month: string;
  now: Date;
  // True for a free code while all free codes together have reached this month's ceiling. Always false for any other code.
  freeFull: boolean;
};
export type GateResult = GateOpen | { ok: false; response: Response };

export function resolveStore(deps: Deps): StudentStore | undefined {
  if (deps.students) return deps.students;
  const db = openDb(deps.env);
  return db ? new PgStudentStore(db) : undefined;
}

// Runs one store call and adds its wall time to the request's db_ms. Any failure becomes a DatabaseError label.
export async function timedDb<T>(ctx: RequestCtx, run: () => Promise<T>): Promise<T> {
  const started = Date.now();
  try {
    return await run();
  } catch (err) {
    if (err instanceof DatabaseError) throw err;
    throw new DatabaseError(`db_error_${err instanceof Error ? err.name : "unknown"}`);
  } finally {
    ctx.noteDb(Date.now() - started);
  }
}

const databaseDown = (ctx: RequestCtx, label: string) => ctx.fail(503, "database_unavailable", label, `database_unavailable:${label}`);

// Everything that must hold before an endpoint reads the body, in this order:
// bearer code present and well formed (401), method (405), the code exists and is not disabled (401/403, database),
// the plan allows it (403), the month's hours are not used up (403), configuration (503), key or scripted mode (503).
export async function gate(ctx: RequestCtx, request: Request, deps: Deps, roles: Role[], options: GateOptions = {}): Promise<GateResult> {
  const { env } = deps;

  const bearer = readBearerCode(request);
  if (!bearer.ok) {
    return { ok: false, response: ctx.fail(401, "unauthorized", bearer.label, `unauthorized:${bearer.label}`) };
  }
  if (request.method !== (options.method ?? "POST")) {
    return { ok: false, response: ctx.fail(405, "method_not_allowed", `use ${options.method ?? "POST"}`, "method_not_allowed") };
  }

  const store = resolveStore(deps);
  if (!store) return { ok: false, response: databaseDown(ctx, "DATABASE_URL is not set") };
  const now = deps.now?.() ?? new Date();
  const month = vancouverMonth(now);
  const hash = codeHash(bearer.code);
  ctx.note({ student: hash });

  let student: StudentRecord | null;
  try {
    student = await timedDb(ctx, () => store.lookup(bearer.code, month));
  } catch (err) {
    return { ok: false, response: databaseDown(ctx, err instanceof DatabaseError ? err.label : "db_error") };
  }
  if (!student) {
    return { ok: false, response: ctx.fail(401, "unauthorized", "unknown_code", "unauthorized:unknown_code") };
  }
  if (student.disabled) {
    return { ok: false, response: ctx.fail(403, "code_disabled", "this code has been turned off", "code_disabled") };
  }

  // Free codes: never live voice (it is billed by the minute, which the server cannot see, so it could not count toward the
  // ceiling), and refused once the month's ceiling is reached. Every other code is untouched by anything in this block.
  let freeFull = false;
  if (student.origin === "free") {
    student = { ...student, planLive: false };
    const ceiling = ceilingOf(env);
    const spent = student.freeSpentMicros ?? 0;
    freeFull = freeIsFull(spent, ceiling.micros);
    ctx.note({ origin: "free", free_spent_usd: microsToUsd(spent), free_ceiling_usd: ceiling.usd, free_full: freeFull });
    if (freeFull && !options.skipFreeCeiling) {
      return {
        ok: false,
        response: ctx.fail(403, "free_tutoring_full", "free tutoring is full this month, it comes back on the 1st", "free_tutoring_full"),
      };
    }
  }

  const allowance = allowanceOf(month, student.usage, student.capSeconds);
  ctx.allowance = allowance;
  ctx.note({ allowance_state: allowance.state, used_seconds: allowance.used_seconds, cap_seconds: allowance.cap_seconds });

  if (options.requireLive && !student.planLive) {
    return { ok: false, response: ctx.fail(403, "live_not_in_plan", "this plan does not include the live voice", "live_not_in_plan") };
  }
  if (allowance.state === "used_up" && !options.allowOverCap) {
    return { ok: false, response: ctx.fail(403, "hours_used_up", "this month's hours are used up", "hours_used_up") };
  }

  const scripted = scriptedState(env);
  if (scripted.refusedInProduction) {
    logLine("error", {
      request_id: ctx.id,
      endpoint: ctx.endpoint,
      outcome: "scripted_refused",
      reason: "TUTOR_SCRIPTED=1 ignored because VERCEL_ENV is production",
    });
  }
  const opened = { student, store, code: bearer.code, month, now, freeFull };
  if (scripted.on) {
    ctx.note({ provider: "scripted", model: "scripted" });
    return { ok: true, scripted: true, configs: {}, keys: {}, ...opened };
  }

  const configs: GateOpen["configs"] = {};
  const keys: GateOpen["keys"] = {};
  for (const role of roles) {
    let cfg: RoleConfig;
    try {
      cfg = roleConfig(role, env);
    } catch (err) {
      const reason = err instanceof ConfigError ? err.message : "bad configuration";
      return { ok: false, response: ctx.fail(503, "bad_config", reason, "bad_config") };
    }
    const key = apiKeyFor(cfg.provider, env);
    if (!key) {
      ctx.note({ provider: cfg.provider, model: cfg.model });
      return { ok: false, response: ctx.fail(503, "missing_key", missingKeyReason(cfg.provider), "missing_key") };
    }
    configs[role] = cfg;
    keys[role] = key;
  }
  const primary = configs[roles[0] as Role];
  if (primary) ctx.note({ provider: primary.provider, model: primary.model });
  return { ok: true, scripted: false, configs, keys, ...opened };
}

// Counts this request's activity moment (see chargeFor in students.ts), then settles the allowance the reply will carry,
// including the one-time "low" (80%) and "used up" (100%) notices. Called by a handler once the request is known to be valid.
// `activityAt` is when the activity really happened: a look or a question happened now, so that is the default. A heartbeat
// passes the time its app reported, or null when it reported none; opening live is not work, so it passes null as well.
// If the database fails here the student is not locked out of the request they already passed the cap check for; the failure
// is logged as an error so it is never silent.
export async function meterActivity(
  ctx: RequestCtx,
  opened: GateOpen,
  kind: ActivityKind,
  activityAt: Date | null = kind === "look" || kind === "question" ? opened.now : null,
): Promise<void> {
  const { store, student, month } = opened;
  try {
    const { usage, charge } = await timedDb(ctx, () => store.chargeActivity(student.id, month, activityAt, kind));
    const settled = allowanceOf(month, usage, student.capSeconds);
    let notice: "low" | "used_up" | null = null;
    if (settled.state === "used_up") {
      if (!usage.usedUpNoticed && (await timedDb(ctx, () => store.claimNotice(student.id, month, "used_up")))) notice = "used_up";
      if (!usage.lowNoticed) await timedDb(ctx, () => store.claimNotice(student.id, month, "low"));
    } else if (settled.state === "low" && !usage.lowNoticed) {
      if (await timedDb(ctx, () => store.claimNotice(student.id, month, "low"))) notice = "low";
    }
    ctx.allowance = { ...settled, notice };
    ctx.note({
      counted_kind: kind,
      charged_seconds: charge.seconds,
      charge_reason: charge.reason,
      ...(charge.gapSeconds === null ? {} : { gap_seconds: charge.gapSeconds }),
      allowance_state: settled.state,
      used_seconds: settled.used_seconds,
      cap_seconds: settled.cap_seconds,
      remaining_minutes: settled.remaining_minutes,
      allowance_notice: notice,
    });
  } catch (err) {
    const label = err instanceof DatabaseError ? err.label : "db_error";
    logLine("error", { request_id: ctx.id, endpoint: ctx.endpoint, student: ctx.fields.student as string, outcome: "meter_failed", reason: label });
  }
}

// The gate resolves watch/ask at the default level so the key check can happen before the body is read. Once the problem
// is known, this picks the model for the problem's level (high_school is already resolved; advanced is resolved here).
// A missing key or bad setting for the advanced model is a 503, same as at the gate.
export type LevelPick = { ok: true; cfg: RoleConfig; key: string } | { ok: false; response: Response };

export function configForLevel(ctx: RequestCtx, opened: GateOpen, env: Env, role: "watch" | "ask", level: Level): LevelPick {
  ctx.note({ level });
  const ready = opened.configs[role];
  const readyKey = opened.keys[role];
  if (level === DEFAULT_LEVEL && ready && readyKey) return { ok: true, cfg: ready, key: readyKey };
  let cfg: RoleConfig;
  try {
    cfg = roleConfig(role, env, level);
  } catch (err) {
    const reason = err instanceof ConfigError ? err.message : "bad configuration";
    return { ok: false, response: ctx.fail(503, "bad_config", reason, "bad_config") };
  }
  const key = apiKeyFor(cfg.provider, env);
  if (!key) {
    ctx.note({ provider: cfg.provider, model: cfg.model });
    return { ok: false, response: ctx.fail(503, "missing_key", missingKeyReason(cfg.provider), "missing_key") };
  }
  ctx.note({ provider: cfg.provider, model: cfg.model });
  return { ok: true, cfg, key };
}

export function issueReason(error: z.ZodError): string {
  const issue = error.issues[0];
  if (!issue) return "invalid request";
  const path = issue.path.join(".") || "body";
  return `${path}: ${issue.message}`;
}
