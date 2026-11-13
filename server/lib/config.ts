// Environment-driven configuration. Everything takes an `env` argument so tests can pass their own.

export type Env = Record<string, string | undefined>;
export type Provider = "openai" | "google";
export type Role = "watch" | "ask" | "stt" | "speak" | "live";
type ProviderRole = Exclude<Role, "speak" | "live">;

// Defaults verified against the vendors' own docs on 2026-11-13. Sources are listed in server/README.md.
export const DEFAULT_MODELS: Record<Provider, Record<ProviderRole, string>> = {
  openai: { watch: "gpt-6.1-sol", ask: "gpt-6.1-terra", stt: "gpt-transcribe" },
  google: { watch: "gemini-4-argon", ask: "gemini-3.8-flash", stt: "gemini-3.5-transcribe" },
};

// The conversational voice: OpenAI GPT-Live-1 over WebRTC (https://developers.openai.com/api/docs/models/gpt-live-1).
// `gleam` is the North American, feminine voice OpenAI lists as a natural (recorded, not generated) voice
// (https://developers.openai.com/api/docs/guides/live-conversations#voice-options). Chosen from the docs, not by ear:
// change it with LIVE_VOICE in Vercel and redeploy. Live is OpenAI only.
export const DEFAULT_LIVE_MODEL = "gpt-live-1";
export const DEFAULT_LIVE_VOICE = "gleam";

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

export type RoleConfig = { role: Role; provider: Provider; model: string };

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

export function roleConfig(role: Role, env: Env): RoleConfig {
  if (role === "speak") {
    return { role, provider: "openai", model: env.SPEAK_MODEL?.trim() || DEFAULT_SPEAK_MODEL };
  }
  if (role === "live") {
    return { role, provider: "openai", model: env.LIVE_MODEL?.trim() || DEFAULT_LIVE_MODEL };
  }
  if (role === "stt") {
    const sttModel = env.STT_MODEL?.trim();
    if (sttModel) {
      const provider: Provider = sttModel.toLowerCase().startsWith("gemini") ? "google" : "openai";
      return { role, provider, model: sttModel };
    }
    // No explicit model: follow the ask provider so one key is enough.
    const provider = parseProvider(env.ASK_PROVIDER, "ASK_PROVIDER");
    return { role, provider, model: DEFAULT_MODELS[provider].stt };
  }
  const providerVar = role === "watch" ? "WATCH_PROVIDER" : "ASK_PROVIDER";
  const modelVar = role === "watch" ? "WATCH_MODEL" : "ASK_MODEL";
  const provider = parseProvider(env[providerVar], providerVar);
  const model = env[modelVar]?.trim() || DEFAULT_MODELS[provider][role];
  return { role, provider, model };
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
