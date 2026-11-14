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
import { checkAuth, type RequestCtx } from "./http.js";
import { logLine } from "./log.js";
import type { LiveGateway } from "./live.js";
import { realModels, type ModelFactory } from "./models.js";

// `live` is the one place the server talks to OpenAI's Live endpoint; tests pass a fake. Unset means the real one.
export type Deps = { env: Env; models: ModelFactory; live?: LiveGateway };
export const defaultDeps = (): Deps => ({ env: process.env, models: realModels });

export type GateOpen = {
  ok: true;
  scripted: boolean;
  configs: Partial<Record<Role, RoleConfig>>;
  keys: Partial<Record<Role, string>>;
};
export type GateResult = GateOpen | { ok: false; response: Response };

// Everything that must hold before a model endpoint reads the body, in this order:
// bearer token (401), POST (405), configuration (503), key or scripted mode (503).
export function gate(ctx: RequestCtx, request: Request, deps: Deps, roles: Role[]): GateResult {
  const { env } = deps;

  const auth = checkAuth(request, env);
  if (!auth.ok) {
    return { ok: false, response: ctx.fail(401, "unauthorized", "missing or invalid bearer token", `unauthorized:${auth.label}`) };
  }
  if (request.method !== "POST") {
    return { ok: false, response: ctx.fail(405, "method_not_allowed", "use POST", "method_not_allowed") };
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
  if (scripted.on) {
    ctx.note({ provider: "scripted", model: "scripted" });
    return { ok: true, scripted: true, configs: {}, keys: {} };
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
  return { ok: true, scripted: false, configs, keys };
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
