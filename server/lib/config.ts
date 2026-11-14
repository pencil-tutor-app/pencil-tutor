// Environment-driven configuration. Everything takes an `env` argument so tests can pass their own.

export type Env = Record<string, string | undefined>;
export type Provider = "openai" | "google";
export type Role = "watch" | "ask" | "stt" | "speak" | "live";
type ProviderRole = Exclude<Role, "speak" | "live">;

// How hard a problem is. `high_school` (the default; every course, college ones too) runs on the cheap model; `advanced`
// runs on the frontier model and is chosen only by a problem's `level: "advanced"` or a course's `tier: "advanced"` in its
// course.json (see problems.ts levelOf). Each level has its own env variables (see roleConfig).
export type Level = "high_school" | "advanced";
export const DEFAULT_LEVEL: Level = "high_school";
export function parseLevel(value: string | undefined): Level {
  return value === "advanced" ? "advanced" : DEFAULT_LEVEL;
}

// Reasoning effort sent to the model. Unset means the provider's own default.
export type Effort = "none" | "low" | "medium" | "high";
function parseEffort(value: string | undefined, varName: string): Effort | undefined {
  const v = value?.trim().toLowerCase();
  if (!v) return undefined;
  if (v === "none" || v === "low" || v === "medium" || v === "high") return v;
  throw new ConfigError(`${varName} must be none, low, medium or high`);
}

// Defaults verified against the vendors' own docs on 2026-11-13 (model ids re-checked against the keys on 2026-11-14).
// Sources are listed in server/README.md.
export const DEFAULT_MODELS: Record<Level, Record<Provider, Record<ProviderRole, string>>> = {
  high_school: {
    // High school math runs on gpt-6-luna for both roles: on the 30-page eval (server/eval/results/main2.md) it matched
    // gpt-6.1-sol's first-wrong-line accuracy (30/30) with 0 false alarms at about a tenth of the cost per look. To go back
    // for a deployment: WATCH_MODEL=gpt-6.1-sol ASK_MODEL=gpt-6.1-terra.
    openai: { watch: "gpt-6-luna", ask: "gpt-6-luna", stt: "gpt-transcribe" },
    google: { watch: "gemini-4-argon", ask: "gemini-3.8-flash", stt: "gemini-3.5-transcribe" },
  },
  advanced: {
    openai: { watch: "gpt-6.1-sol", ask: "gpt-6.1-sol", stt: "gpt-transcribe" },
    google: { watch: "gemini-4-argon", ask: "gemini-4-argon", stt: "gemini-3.5-transcribe" },
  },
};
// Default reasoning effort per level and role (undefined = the provider's default).
export const DEFAULT_EFFORT: Record<Level, Partial<Record<ProviderRole, Effort>>> = { high_school: {}, advanced: {} };

// The conversational voice: OpenAI GPT-Live-1 over WebRTC (https://developers.openai.com/api/docs/models/gpt-live-1).
// `meridian` is the male voice Edward asked for (2026-11-14); production already sets LIVE_VOICE=meridian. The voice table
// is at https://developers.openai.com/api/docs/guides/live-conversations#voice-options. Change it with LIVE_VOICE in Vercel
// and redeploy. Live is OpenAI only.
export const DEFAULT_LIVE_MODEL = "gpt-live-1";
export const DEFAULT_LIVE_VOICE = "meridian";

export type LiveSettings = { voice: string };

export function liveSettings(env: Env): LiveSettings {
  return { voice: env.LIVE_VOICE?.trim() || DEFAULT_LIVE_VOICE };
}

// Text-to-speech is OpenAI only (the speak role has no provider setting). This is the FALLBACK voice now.
// OpenAI lists gpt-4o-mini-tts as deprecated with shutdown on 2027-01-06
// (https://developers.openai.com/api/docs/deprecations); after that date the app falls back to the device voice.
export const DEFAULT_SPEAK_MODEL = "gpt-4o-mini-tts";
export const DEFAULT_SPEAK_VOICE = "coral";
export const DEFAULT_SPEAK_INSTRUCTIONS =
  "Warm, patient math tutor talking to a 14-year-old. Calm, encouraging, natural pace. Say math aloud plainly.";

export type SpeakSettings = { voice: string; instructions: string };

export function speakSettings(env: Env): SpeakSettings {
  return {
    voice: env.SPEAK_VOICE?.trim() || DEFAULT_SPEAK_VOICE,
    instructions: env.SPEAK_INSTRUCTIONS?.trim() || DEFAULT_SPEAK_INSTRUCTIONS,
  };
}

// First name is the one reported in the 503 message; the others are also accepted.
export const KEY_NAMES: Record<Provider, string[]> = {
  openai: ["OPENAI_API_KEY"],
  google: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
};

export type RoleConfig = { role: Role; provider: Provider; model: string; level: Level; effort?: Effort };

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

function parseProvider(value: string | undefined, varName: string): Provider {
  const v = (value ?? "openai").trim().toLowerCase();
  if (v === "openai" || v === "google") return v;
  throw new ConfigError(`${varName} must be "openai" or "google"`);
}

// `level` is the problem difficulty. high_school reads WATCH_PROVIDER / WATCH_MODEL / WATCH_EFFORT (and the ASK_ twins);
// advanced reads the same names with an _ADVANCED suffix. speak, live and stt do not depend on level.
export function roleConfig(role: Role, env: Env, level: Level = DEFAULT_LEVEL): RoleConfig {
  if (role === "speak") {
    return { role, provider: "openai", model: env.SPEAK_MODEL?.trim() || DEFAULT_SPEAK_MODEL, level };
  }
  if (role === "live") {
    return { role, provider: "openai", model: env.LIVE_MODEL?.trim() || DEFAULT_LIVE_MODEL, level };
  }
  if (role === "stt") {
    const sttModel = env.STT_MODEL?.trim();
    if (sttModel) {
      const provider: Provider = sttModel.toLowerCase().startsWith("gemini") ? "google" : "openai";
      return { role, provider, model: sttModel, level };
    }
    // No explicit model: follow the ask provider so one key is enough.
    const provider = parseProvider(env.ASK_PROVIDER, "ASK_PROVIDER");
    return { role, provider, model: DEFAULT_MODELS[DEFAULT_LEVEL][provider].stt, level };
  }
  const suffix = level === "advanced" ? "_ADVANCED" : "";
  const stem = role === "watch" ? "WATCH" : "ASK";
  const providerVar = `${stem}_PROVIDER${suffix}`;
  const modelVar = `${stem}_MODEL${suffix}`;
  const effortVar = `${stem}_EFFORT${suffix}`;
  const provider = parseProvider(env[providerVar], providerVar);
  const model = env[modelVar]?.trim() || DEFAULT_MODELS[level][provider][role];
  const effort = parseEffort(env[effortVar], effortVar) ?? DEFAULT_EFFORT[level][role];
  return effort ? { role, provider, model, level, effort } : { role, provider, model, level };
}

export function apiKeyFor(provider: Provider, env: Env): string | undefined {
  for (const name of KEY_NAMES[provider]) {
    const value = env[name]?.trim();
    if (value) return value;
  }
  return undefined;
}

export function missingKeyReason(provider: Provider): string {
  return `${KEY_NAMES[provider][0]} is not set`;
}

export type ScriptedState = { on: boolean; refusedInProduction: boolean };

// TUTOR_SCRIPTED=1 answers from a fixed script with no key. Never in production.
export function scriptedState(env: Env): ScriptedState {
  const requested = env.TUTOR_SCRIPTED === "1";
  if (requested && env.VERCEL_ENV === "production") return { on: false, refusedInProduction: true };
  return { on: requested, refusedInProduction: false };
}

export function appVersion(env: Env): string {
  return env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) || "0.1.0";
}
