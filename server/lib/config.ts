// Environment-driven configuration. Everything takes an `env` argument so tests can pass their own.

export type Env = Record<string, string | undefined>;
export type Provider = "openai" | "google";
export type Role = "watch" | "ask" | "stt";

// Defaults verified against the vendors' own docs on 2026-11-13. Sources are listed in server/README.md.
export const DEFAULT_MODELS: Record<Provider, Record<Role, string>> = {
  openai: { watch: "gpt-6.1-sol", ask: "gpt-6.1-terra", stt: "gpt-transcribe" },
  google: { watch: "gemini-4-argon", ask: "gemini-3.8-flash", stt: "gemini-3.5-transcribe" },
};

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
