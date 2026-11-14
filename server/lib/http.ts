import { randomUUID } from "node:crypto";
import { logLine, type LogFields } from "./log.js";
import { isValidCode, type Allowance } from "./students.js";

// A request in flight: owns the id, the clock and the single log line written when it finishes.
export class RequestCtx {
  readonly id = randomUUID();
  readonly startedAt = Date.now();
  readonly fields: LogFields;
  // Set once the student is known and their time is counted; every reply after that carries it.
  allowance: Allowance | null = null;

  constructor(
    readonly endpoint: "watch" | "ask" | "speak" | "health" | "live-session" | "consult" | "me" | "heartbeat",
    readonly method: string,
  ) {
    this.fields = { request_id: this.id, endpoint, method };
  }

  note(extra: LogFields): void {
    Object.assign(this.fields, extra);
  }

  // Adds up the time spent waiting on the database in this request (a count and a total, for the log line).
  noteDb(ms: number): void {
    this.fields.db_queries = Number(this.fields.db_queries ?? 0) + 1;
    this.fields.db_ms = Number(this.fields.db_ms ?? 0) + ms;
  }

  // Builds the response and writes the one log line. `outcome` is a short label, `reason` a label (never content).
  respond(status: number, body: Record<string, unknown>, outcome: string, reason?: string): Response {
    const latency_ms = Date.now() - this.startedAt;
    const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
    logLine(level, { ...this.fields, status, outcome, reason, latency_ms });
    const withAllowance = this.allowance && body.allowance === undefined ? { ...body, allowance: this.allowance } : body;
    return new Response(JSON.stringify({ ...withAllowance, request_id: this.id }), {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store", "x-request-id": this.id },
    });
  }

  private allowanceHeaders(): Record<string, string> {
    if (!this.allowance) return {};
    return {
      "x-allowance-state": this.allowance.state,
      "x-allowance-remaining-seconds": String(this.allowance.remaining_seconds),
    };
  }

  // Binary reply (audio). Same single log line as respond(); `extra` headers carry the small facts the client wants.
  respondBytes(bytes: Uint8Array, contentType: string, outcome: string, reason: string, extra: Record<string, string> = {}): Response {
    const latency_ms = Date.now() - this.startedAt;
    logLine("info", { ...this.fields, status: 200, outcome, reason, latency_ms });
    return new Response(bytes as BodyInit, {
      status: 200,
      headers: {
        "content-type": contentType,
        "content-length": String(bytes.length),
        "cache-control": "no-store",
        "x-request-id": this.id,
        "x-latency-ms": String(latency_ms),
        ...this.allowanceHeaders(),
        ...extra,
      },
    });
  }

  // Streamed binary reply (audio that starts playing before it is all generated). The log line is written when the first
  // bytes are ready (that is the time the student waits); the caller writes a second line when the stream ends.
  respondStream(body: ReadableStream<Uint8Array>, contentType: string, outcome: string, reason: string, extra: Record<string, string> = {}): Response {
    const latency_ms = Date.now() - this.startedAt;
    logLine("info", { ...this.fields, status: 200, outcome, reason, latency_ms, first_audio_ms: latency_ms });
    return new Response(body as BodyInit, {
      status: 200,
      headers: {
        "content-type": contentType,
        "cache-control": "no-store",
        "x-request-id": this.id,
        "x-latency-ms": String(latency_ms),
        ...this.allowanceHeaders(),
        ...extra,
      },
    });
  }

  fail(status: number, error: string, reason: string, outcome = error): Response {
    return this.respond(status, { error, reason }, outcome, reason);
  }
}

// The code from `Authorization: Bearer <CODE>`. The shape is checked here so junk never reaches the database.
export type BearerResult =
  | { ok: true; code: string }
  | { ok: false; label: "missing_header" | "bad_scheme" | "malformed_code" };

export function readBearerCode(request: Request): BearerResult {
  const header = request.headers.get("authorization");
  if (!header) return { ok: false, label: "missing_header" };
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return { ok: false, label: "bad_scheme" };
  const code = (match[1] ?? "").trim();
  if (!isValidCode(code)) return { ok: false, label: "malformed_code" };
  return { ok: true, code };
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
