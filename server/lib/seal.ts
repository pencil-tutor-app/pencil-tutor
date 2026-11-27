import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import type { Env } from "./config.js";
import { scriptedState } from "./config.js";

// The sealed reference of a practice problem: the worked solution and final answer, encrypted so the iPad can carry them to
// the server without ever holding them readable, and so a request cannot place its own text in the "reference" block of a prompt.
// AES-256-GCM, a fresh 12 byte nonce per seal, the problem's course and statement inside the sealed payload. The statement is sealed
// too, so a request needs only the token and the id: when it also sends the statement (own problems always do) the two must match.

export const SEAL_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const VERSION = "t1";
const AAD = Buffer.from("pencil-tutor-teach-reference-v1");

export type SealedReference = { course: string; worked_solution: string[]; final_answer: string };

export type OpenFailure = "malformed" | "bad_seal" | "expired" | "wrong_course" | "text_mismatch";
export type SealedOpened = SealedReference & { prompt_plain: string };
export type OpenResult = { ok: true; reference: SealedOpened } | { ok: false; label: OpenFailure };

// A fixed key for scripted mode only (tests and the iPad UI test); scriptedState refuses scripted mode in production.
const SCRIPTED_KEY = createHash("sha256").update("pencil-tutor-scripted-teach-seal-key").digest();

// TEACH_SEAL_KEY is 32 random bytes written as 64 hex characters or as base64. Anything else is no key.
export function sealKeyFor(env: Env): Buffer | null {
  const raw = env.TEACH_SEAL_KEY?.trim();
  if (raw) {
    const key = /^[0-9a-fA-F]{64}$/.test(raw) ? Buffer.from(raw, "hex") : Buffer.from(raw, "base64");
    return key.length === 32 ? key : null;
  }
  return scriptedState(env).on ? SCRIPTED_KEY : null;
}

const cleaned = (promptPlain: string) => promptPlain.replace(/\s+/g, " ").trim();

export function sealReference(key: Buffer, reference: SealedReference, promptPlain: string, now: Date): string {
  const payload = JSON.stringify({ course: reference.course, prompt: cleaned(promptPlain), steps: reference.worked_solution, answer: reference.final_answer, exp: now.getTime() + SEAL_TTL_MS });
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(AAD);
  const body = Buffer.concat([cipher.update(payload, "utf8"), cipher.final()]);
  return `${VERSION}.${Buffer.concat([iv, cipher.getAuthTag(), body]).toString("base64url")}`;
}

// Opens a token for the course the request names, and for the statement when it names one. Every failure is a short label, never a message.
export function openReference(key: Buffer, token: string, expected: { course: string; promptPlain?: string }, now: Date): OpenResult {
  const [version, packed] = token.split(".");
  if (version !== VERSION || !packed) return { ok: false, label: "malformed" };
  const bytes = Buffer.from(packed, "base64url");
  if (bytes.length < 12 + 16 + 1) return { ok: false, label: "malformed" };
  let text: string;
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, 12));
    decipher.setAAD(AAD);
    decipher.setAuthTag(bytes.subarray(12, 28));
    text = Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString("utf8");
  } catch {
    return { ok: false, label: "bad_seal" };
  }
  let payload: { course?: unknown; prompt?: unknown; steps?: unknown; answer?: unknown; exp?: unknown };
  try {
    payload = JSON.parse(text);
  } catch {
    return { ok: false, label: "malformed" };
  }
  const { course, prompt, steps, answer, exp } = payload;
  if (typeof course !== "string" || typeof prompt !== "string" || typeof answer !== "string" || typeof exp !== "number" || !Array.isArray(steps) || !steps.every((s) => typeof s === "string")) {
    return { ok: false, label: "malformed" };
  }
  if (exp <= now.getTime()) return { ok: false, label: "expired" };
  if (course !== expected.course) return { ok: false, label: "wrong_course" };
  if (expected.promptPlain !== undefined && prompt !== cleaned(expected.promptPlain)) return { ok: false, label: "text_mismatch" };
  return { ok: true, reference: { course, worked_solution: steps as string[], final_answer: answer, prompt_plain: prompt } };
}
