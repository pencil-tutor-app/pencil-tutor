import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import type { Env } from "./config.js";
import { logLine, type LogFields } from "./log.js";

// A request in flight: owns the id, the clock and the single log line written when it finishes.
export class RequestCtx {
  readonly id = randomUUID();
  readonly startedAt = Date.now();
  readonly fields: LogFields;

  constructor(
    readonly endpoint: "watch" | "ask" | "health",
    readonly method: string,
  ) {
    this.fields = { request_id: this.id, endpoint, method };
  }

  note(extra: LogFields): void {
    Object.assign(this.fields, extra);
  }

  // Builds the response and writes the one log line. `outcome` is a short label, `reason` a label (never content).
  respond(status: number, body: Record<string, unknown>, outcome: string, reason?: string): Response {
    const latency_ms = Date.now() - this.startedAt;
    const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
    logLine(level, { ...this.fields, status, outcome, reason, latency_ms });
    return new Response(JSON.stringify({ ...body, request_id: this.id }), {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store", "x-request-id": this.id },
    });
  }

  fail(status: number, error: string, reason: string, outcome = error): Response {
    return this.respond(status, { error, reason }, outcome, reason);
  }
}

export type AuthResult = { ok: true } | { ok: false; label: "token_not_configured" | "missing_header" | "bad_scheme" | "bad_token" };

const sha = (s: string) => createHash("sha256").update(s).digest();

export function checkAuth(request: Request, env: Env): AuthResult {
  const expected = env.APP_ACCESS_TOKEN;
  if (!expected) return { ok: false, label: "token_not_configured" };
  const header = request.headers.get("authorization");
  if (!header) return { ok: false, label: "missing_header" };
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return { ok: false, label: "bad_scheme" };
  const same = timingSafeEqual(sha(match[1] ?? ""), sha(expected));
  return same ? { ok: true } : { ok: false, label: "bad_token" };
}

export const MAX_BODY_CHARS = 3_000_000;

export type JsonBody = { ok: true; value: unknown } | { ok: false; status: number; error: string; reason: string };

export async function readJson(request: Request): Promise<JsonBody> {
  let text: string;
  try {
    text = await request.text();
  } catch {
    return { ok: false, status: 400, error: "bad_request", reason: "body_unreadable" };
  }
  if (text.length > MAX_BODY_CHARS) return { ok: false, status: 413, error: "too_large", reason: "body_over_3_MB" };
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false, status: 400, error: "bad_request", reason: "body_not_json" };
  }
}
