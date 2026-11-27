import { apiKeyFor, appVersion, ConfigError, liveSettings, roleConfig, scriptedState, teachLevel, type Env, type Role } from "./config.js";
import { databaseUrl } from "./db.js";
import { voiceSummary } from "./voice.js";
import { RequestCtx } from "./http.js";
import { problemCount } from "./problems.js";
import { sealKeyFor } from "./seal.js";

// GET /api/health: no auth, no secrets. Says which keys exist (yes/no only) and which models are configured.
export function handleHealth(request: Request, env: Env = process.env): Response {
  const ctx = new RequestCtx("health", request.method);
  const scripted = scriptedState(env);

  const models: Record<string, { provider: string; model: string; effort?: string } | { error: string }> = {};
  for (const role of ["watch", "ask", "stt", "speak", "live"] as Role[]) {
    try {
      const { provider, model, effort } = roleConfig(role, env);
      models[role] = effort ? { provider, model, effort } : { provider, model };
    } catch (err) {
      models[role] = { error: err instanceof ConfigError ? err.message : "bad configuration" };
    }
  }

  // The model used for advanced (college level and harder) problems. High school problems use `models`.
  const modelsAdvanced: Record<string, { provider: string; model: string } | { error: string }> = {};
  for (const role of ["watch", "ask"] as Role[]) {
    try {
      const { provider, model } = roleConfig(role, env, "advanced");
      modelsAdvanced[role] = { provider, model };
    } catch (err) {
      modelsAdvanced[role] = { error: err instanceof ConfigError ? err.message : "bad configuration" };
    }
  }

  const openai = Boolean(apiKeyFor("openai", env));
  const google = Boolean(apiKeyFor("google", env));
  ctx.note({ openai_key: openai, google_key: google, scripted: scripted.on, teach_ready: sealKeyFor(env) !== null });
  return ctx.respond(
    200,
    {
      ok: true,
      version: appVersion(env),
      vercel_env: env.VERCEL_ENV ?? null,
      openai_key_present: openai,
      gemini_key_present: google,
      database_configured: Boolean(databaseUrl(env)),
      voice_provider: voiceSummary(env).provider,
      voice: voiceSummary(env),
      scripted: scripted.on,
      scripted_refused_in_production: scripted.refusedInProduction,
      models,
      models_advanced: modelsAdvanced,
      live_voice: liveSettings(env).voice,
      problems: problemCount,
      // Whether practice problems can be sealed (a valid TEACH_SEAL_KEY, or scripted mode). Never the key.
      teach_ready: sealKeyFor(env) !== null,
      teach_level: teachLevel(env),
    },
    "ok",
    "health",
  );
}
