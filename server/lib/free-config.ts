import { createHmac } from "node:crypto";
import { isIP } from "node:net";
import type { Env } from "./config.js";
import { audioRateFor, rateFor } from "./pricing.js";
import type { UsageReport } from "./usage.js";

// Free codes: the settings, the address handling and the cost arithmetic. Pure functions, no database and no request, so they are
// tested on their own. The plan and the reasons for every number are in docs/free-launch-plan.md.

export type StudentOrigin = "admin" | "free";

// ----- Settings (environment) -----

export const DEFAULT_CEILING_USD = 50;
export const DEFAULT_PER_IP_PER_DAY = 3;
export const IP_WINDOW_MS = 24 * 3600 * 1000;
// A stored address hash that has not been touched for this long is useless (the window is 24 hours) and is deleted.
export const STALE_IP_ROW_MS = 48 * 3600 * 1000;
export const MIN_SALT_CHARS = 16;
// The most a text call may generate for a free code, reasoning included (sent to the provider as maxOutputTokens).
export const DEFAULT_MAX_OUTPUT_TOKENS = 3000;
// Assumed bound on one text call's input: the image is at most 1024 px and 400 KB (lib/image.ts), the prompt text is capped by schema.
// A look measured 1,841 input tokens (docs/how-to-run.md), so this is about 13 times that. It is the one assumed number in the bound.
export const INPUT_TOKEN_BOUND = 25_000;
// A free code's recording may not be longer than this. The app's 30-second limit measured 26 to 114 KB with its recorder settings.
export const FREE_MAX_AUDIO_BYTES = 300_000;
// Fewer bytes per second than any recording measured (882 for silence, 1,851 for voice-like tone, 3,791 for noise), so bytes / this
// is at least the real length of the app's own recordings.
export const STT_FLOOR_BYTES_PER_SECOND = 800;
// The slowest speech assumed for the OpenAI fallback voice, and the PCM wire format it returns (16-bit mono at 24 kHz).
export const SPEECH_SLOW_CHARS_PER_MINUTE = 600;
export const PCM_BYTES_PER_SECOND = 48_000;
// models.ts calls generateText, transcribe and generateSpeech with maxRetries: 1 (up to two attempts); the reword call has none.
export const RETRIED_ATTEMPTS = 2;

export type Source = "env" | "default" | "invalid_env_using_default";

const clean = (value: string | undefined): string | undefined => {
  const v = value?.trim();
  return v ? v : undefined;
};

export function ceilingOf(env: Env): { usd: number; micros: number; source: Source } {
  const raw = clean(env.FREE_MONTHLY_CEILING_USD);
  if (raw === undefined) return { usd: DEFAULT_CEILING_USD, micros: usdToMicros(DEFAULT_CEILING_USD), source: "default" };
  const usd = Number(raw);
  // 0 is allowed on purpose: it closes free tutoring (the kill switch). Anything that is not a number is NOT "no limit".
  if (!Number.isFinite(usd) || usd < 0) return { usd: DEFAULT_CEILING_USD, micros: usdToMicros(DEFAULT_CEILING_USD), source: "invalid_env_using_default" };
  return { usd, micros: usdToMicros(usd), source: "env" };
}

export function perIpLimit(env: Env): { limit: number; source: Source } {
  const raw = clean(env.FREE_CODE_PER_IP_PER_DAY);
  if (raw === undefined) return { limit: DEFAULT_PER_IP_PER_DAY, source: "default" };
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 100) return { limit: DEFAULT_PER_IP_PER_DAY, source: "invalid_env_using_default" };
  return { limit: n, source: "env" };
}

export function maxOutputTokensOf(env: Env): number {
  const n = Number(clean(env.FREE_MAX_OUTPUT_TOKENS));
  return Number.isInteger(n) && n >= 100 && n <= 20_000 ? n : DEFAULT_MAX_OUTPUT_TOKENS;
}

export type SaltState = { ok: true; salt: string } | { ok: false; reason: "ip_salt_not_set" | "ip_salt_too_short" };

// No salt, no free codes: an unkeyed hash of an address would be easy to reverse (there are only 2^32 IPv4 addresses).
export function saltOf(env: Env): SaltState {
  const salt = clean(env.FREE_CODE_IP_SALT);
  if (!salt) return { ok: false, reason: "ip_salt_not_set" };
  if (salt.length < MIN_SALT_CHARS) return { ok: false, reason: "ip_salt_too_short" };
  return { ok: true, salt };
}

// What the settings say, with no secret in it, for /api/health and the admin tool.
export function freeSummary(env: Env) {
  const salt = saltOf(env);
  const ceiling = ceilingOf(env);
  const open = salt.ok && ceiling.micros > 0;
  return {
    creation: open ? "on" : "off",
    reason: salt.ok ? (ceiling.micros > 0 ? null : "ceiling_is_zero") : salt.reason,
    ceiling_usd: ceiling.usd,
    ceiling_source: ceiling.source,
    per_ip_per_day: perIpLimit(env).limit,
  };
}

// ----- Money -----

// Millionths of a dollar, rounded up so an estimate is never made smaller by rounding. The toFixed removes float fuzz such as
// 0.008 * 1e6 = 8000.000000000001.
export const usdToMicros = (usd: number): number => Math.max(0, Math.ceil(Number((usd * 1e6).toFixed(3))));
export const microsToUsd = (micros: number): number => micros / 1e6;
export const freeIsFull = (spentMicros: number, ceilingMicros: number): boolean => spentMicros >= ceilingMicros;

// ----- The network address -----

// IPv6 is grouped by its first 64 bits (one household or one phone gets a whole /64, so rotating inside it must not help).
function expandIpv6(input: string): number[] | null {
  let text = input;
  const zone = text.indexOf("%");
  if (zone >= 0) text = text.slice(0, zone);
  let embedded: number[] = [];
  const lastColon = text.lastIndexOf(":");
  const last = text.slice(lastColon + 1);
  if (last.includes(".")) {
    const octets = last.split(".").map(Number);
    if (octets.length !== 4 || octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
    embedded = [((octets[0] as number) << 8) | (octets[1] as number), ((octets[2] as number) << 8) | (octets[3] as number)];
    text = `${text.slice(0, lastColon + 1)}0:0`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const parse = (part: string): number[] => (part === "" ? [] : part.split(":").map((h) => parseInt(h, 16)));
  const head = parse(halves[0] ?? "");
  const rest = halves.length === 2 ? parse(halves[1] ?? "") : [];
  const groups = halves.length === 2 ? [...head, ...new Array<number>(Math.max(0, 8 - head.length - rest.length)).fill(0), ...rest] : head;
  if (groups.length !== 8 || groups.some((n) => !Number.isInteger(n) || n < 0 || n > 0xffff)) return null;
  if (embedded.length === 2) {
    groups[6] = embedded[0] as number;
    groups[7] = embedded[1] as number;
  }
  return groups;
}

// The form that is rate limited: an IPv4 address as it is, an IPv6 address as its /64, an IPv4-mapped IPv6 address as the IPv4. Null
// when the text is not an address.
export function normalizeAddress(raw: string): string | null {
  const text = raw.trim();
  const kind = isIP(text);
  if (kind === 4) return text;
  if (kind !== 6) return null;
  const groups = expandIpv6(text);
  if (!groups) return null;
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    const g6 = groups[6] as number;
    const g7 = groups[7] as number;
    return `${g6 >> 8}.${g6 & 255}.${g7 >> 8}.${g7 & 255}`;
  }
  return `${groups.slice(0, 4).map((g) => g.toString(16)).join(":")}::/64`;
}

// Vercel sets all three to the client's address and overwrites any value the client sent (https://vercel.com/docs/headers/request-headers,
// read 2026-11-19; not yet observed on a deployment, see the rollout checks in the plan). The first usable one wins.
export const ADDRESS_HEADERS = ["x-vercel-forwarded-for", "x-real-ip", "x-forwarded-for"] as const;

export function clientAddress(headers: Headers): string | null {
  for (const name of ADDRESS_HEADERS) {
    const value = headers.get(name);
    if (!value) continue;
    const first = value.split(",")[0] ?? "";
    const address = normalizeAddress(first);
    if (address) return address;
  }
  return null;
}

// A keyed hash (HMAC-SHA-256), 32 hex characters. The raw address is never stored or logged.
export function hashAddress(address: string, salt: string): string {
  return createHmac("sha256", salt).update(`pencil-tutor-free-ip:${address}`).digest("hex").slice(0, 32);
}

// ----- The cost of one paid call: the worst case to reserve first, and the estimate to settle to -----

// `total` covers every attempt the SDK may make; `perAttempt` is one attempt, kept when a call succeeded but reported nothing.
export type Reserve = { total: number; perAttempt: number };

const reserveOf = (perAttemptUsd: number, attempts: number): Reserve => {
  const perAttempt = usdToMicros(perAttemptUsd);
  return { perAttempt, total: perAttempt * attempts };
};

// A text model call: the input bound plus the output cap, both at the model's own price. Undefined when the model has no price.
export function textReserve(model: string, at: Date, maxOutputTokens: number, attempts = RETRIED_ATTEMPTS): Reserve | undefined {
  const rate = rateFor(model, at);
  if (!rate) return undefined;
  return reserveOf((INPUT_TOKEN_BOUND * rate.input + maxOutputTokens * rate.output) / 1_000_000, attempts);
}

// Speech to text: the recording's bytes at the floor rate give its longest plausible length.
export function sttReserve(model: string, audioBytes: number): Reserve | undefined {
  const perMinute = audioRateFor(model);
  if (perMinute === undefined) return undefined;
  return reserveOf((audioBytes / STT_FLOOR_BYTES_PER_SECOND / 60) * perMinute, RETRIED_ATTEMPTS);
}

export function sttActualMicros(model: string, seconds: number): number | undefined {
  const perMinute = audioRateFor(model);
  return perMinute === undefined ? undefined : usdToMicros((seconds / 60) * perMinute);
}

// The OpenAI fallback voice: the text is at most 600 characters, spoken at the slowest assumed pace.
export function speechReserve(model: string, chars: number): Reserve | undefined {
  const perMinute = audioRateFor(model);
  if (perMinute === undefined) return undefined;
  return reserveOf((chars / SPEECH_SLOW_CHARS_PER_MINUTE) * perMinute, RETRIED_ATTEMPTS);
}

export function speechActualMicros(model: string, pcmBytes: number): number | undefined {
  const perMinute = audioRateFor(model);
  return perMinute === undefined ? undefined : usdToMicros((pcmBytes / PCM_BYTES_PER_SECOND / 60) * perMinute);
}

// What a call is finally counted at, and why. The reserve is the bound; the settle moves the total from the reserve to this.
export type CountBasis =
  | "estimated" // the provider reported usage and the model has a price
  | "reserve_kept_no_usage" // the call worked but reported nothing usable: one attempt's bound stays counted
  | "reserve_kept_failed" // the call failed or timed out: it may have been billed, so the whole reserve stays counted
  | "not_called"; // the call never happened (an earlier step failed): the reserve is given back
export type Counted = { micros: number; basis: CountBasis; detail?: string };

// For a text call. `failure` is the label of a failed call, or null when it returned.
export function countText(usage: UsageReport | undefined, failure: string | null, reserve: Reserve): Counted {
  if (failure !== null) return { micros: reserve.total, basis: "reserve_kept_failed", detail: failure };
  if (usage && usage.est_cost_usd !== null) return { micros: usdToMicros(usage.est_cost_usd), basis: "estimated" };
  return { micros: reserve.perAttempt, basis: "reserve_kept_no_usage", detail: usage?.cost_basis ?? "no_usage" };
}

export const notCalled: Counted = { micros: 0, basis: "not_called" };
export const addCounted = (a: Counted, b: Counted): Counted => {
  // The least certain basis wins, so the log says the truth about the sum.
  const order: CountBasis[] = ["not_called", "estimated", "reserve_kept_no_usage", "reserve_kept_failed"];
  const basis = order[Math.max(order.indexOf(a.basis), order.indexOf(b.basis))] as CountBasis;
  return { micros: a.micros + b.micros, basis, detail: a.detail ?? b.detail };
};
export const addReserve = (a: Reserve, b: Reserve): Reserve => ({ total: a.total + b.total, perAttempt: a.perAttempt + b.perAttempt });
