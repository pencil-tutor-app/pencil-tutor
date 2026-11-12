import { apiKeyFor, appVersion, ConfigError, roleConfig, scriptedState, type Env, type Role } from "./config.js";
import { RequestCtx } from "./http.js";
import { problemCount } from "./problems.js";

// GET /api/health: no auth, no secrets. Says which keys exist (yes/no only) and which models are configured.
export function handleHealth(request: Request, env: Env = process.env): Response {
  const ctx = new RequestCtx("health", request.method);
  const scripted = scriptedState(env);

  const models: Record<string, { provider: string; model: string } | { error: string }> = {};
  for (const role of ["watch", "ask", "stt"] as Role[]) {
    try {
      const { provider, model } = roleConfig(role, env);
      models[role] = { provider, model };
    } catch (err) {
      models[role] = { error: err instanceof ConfigError ? err.message : "bad configuration" };
    }
  }

  const openai = Boolean(apiKeyFor("openai", env));
  const google = Boolean(apiKeyFor("google", env));
  ctx.note({ openai_key: openai, google_key: google, scripted: scripted.on });
  return ctx.respond(
    200,
    {
      ok: true,
      version: appVersion(env),
      vercel_env: env.VERCEL_ENV ?? null,
      openai_key_present: openai,
      gemini_key_present: google,
      app_token_set: Boolean(env.APP_ACCESS_TOKEN),
      scripted: scripted.on,
      scripted_refused_in_production: scripted.refusedInProduction,
      models,
      problems: problemCount,
    },
    "ok",
    "health",
  );
}
