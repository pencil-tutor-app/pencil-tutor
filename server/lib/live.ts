import { z } from "zod";
import { liveSettings } from "./config.js";
import { defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { buildLiveInstructions, LIVE_GREETING } from "./policy.js";
import { problemFields } from "./problems.js";
import { resolveRequestProblem } from "./teach-ref.js";

// The only client events the iPad may send on the data channel. All five are named in OpenAI's Live guides
// (live-conversations: mute/unmute, thinking/commentary append, close). Anything else is refused by OpenAI, so a
// leaked app token cannot be used to rewrite the tutor's instructions mid-session.
export const ALLOWED_CLIENT_EVENTS = [
  "session.input_audio.mute",
  "session.input_audio.unmute",
  "session.thinking.append",
  "session.commentary.append",
  "session.close",
] as const;

export const MAX_SDP_CHARS = 65_536;
const LIVE_SESSIONS_URL = "https://api.openai.com/v1/live/sessions";
const LIVE_TIMEOUT_MS = 15_000;

const LiveSessionRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  // The typed statement of an own problem ("own:<course>"); required then, ignored for a bank id (problems.ts resolveProblem).
  problem_text: z.string().optional(),
  // The sealed reference of a teach practice problem (lib/seal.ts). The voice still never receives the solution; the reference
  // only tells the server this is a practice problem, so the instructions carry the no-answer rule (policy.ts LIVE_TEACH_NOTE).
  problem_ref: z.string().max(6000).optional(),
  sdp: z
    .string()
    .min(1, "sdp must be the WebRTC offer")
    .max(MAX_SDP_CHARS, "sdp over 64 KB")
    .refine((s) => s.trimStart().startsWith("v=0"), "sdp does not look like a session description"),
});

export type LiveSessionConfig = {
  model: string;
  instructions: string;
  input: unknown[];
  audio: { output: { voice: string } };
  client: { data_channel: { allowed_client_events: readonly string[]; allowed_server_events: "all" } };
  delegation: { type: "client" };
};

export type LiveCreateResult =
  | { kind: "created"; sessionId: string; answerSdp: string }
  | { kind: "failed"; status: 502 | 504; error: "model_error" | "model_timeout"; label: string };

// One seam: "make a Live WebRTC session from this offer". The real one is a plain fetch (no SDK needed).
export interface LiveGateway {
  createWebRtcSession(args: { apiKey: string; session: LiveSessionConfig; sdp: string }): Promise<LiveCreateResult>;
}

export const realLive: LiveGateway = {
  async createWebRtcSession({ apiKey, session, sdp }) {
    let response: Response;
    try {
      response = await fetch(LIVE_SESSIONS_URL, {
        method: "POST",
        headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ session, transport: { type: "webrtc", sdp } }),
        signal: AbortSignal.timeout(LIVE_TIMEOUT_MS),
      });
    } catch (err) {
      const name = err instanceof Error ? err.name : "";
      if (name === "TimeoutError" || name === "AbortError") {
        return { kind: "failed", status: 504, error: "model_timeout", label: "provider_timeout" };
      }
      return { kind: "failed", status: 502, error: "model_error", label: `provider_error_${name || "unknown"}` };
    }
    // Never copy the provider's message into our reply or logs: it can echo request details.
    if (response.status !== 200 && response.status !== 201) {
      return { kind: "failed", status: 502, error: "model_error", label: `provider_http_${response.status}` };
    }
    let parsed: unknown;
    try {
      parsed = await response.json();
    } catch {
      return { kind: "failed", status: 502, error: "model_error", label: "provider_reply_not_json" };
    }
    const reply = z
      .object({ session: z.object({ id: z.string().min(1) }), transport: z.object({ sdp: z.string().min(1) }) })
      .safeParse(parsed);
    if (!reply.success) return { kind: "failed", status: 502, error: "model_error", label: "provider_reply_shape" };
    return { kind: "created", sessionId: reply.data.session.id, answerSdp: reply.data.transport.sdp };
  },
};

export function buildLiveSession(args: { model: string; voice: string; instructions: string }): LiveSessionConfig {
  return {
    model: args.model,
    instructions: args.instructions,
    // The greeting is a developer message at startup; the app also sends it once as commentary after session.started
    // (OpenAI's documented greeting sequence). The model may paraphrase or stay silent.
    input: [{ type: "message", role: "developer", content: [{ type: "input_text", text: LIVE_GREETING }] }],
    audio: { output: { voice: args.voice } },
    client: { data_channel: { allowed_client_events: ALLOWED_CLIENT_EVENTS, allowed_server_events: "all" } },
    delegation: { type: "client" },
  };
}

// POST /api/live-session: the iPad's WebRTC offer in, OpenAI's answer out. The project key never leaves this function.
// Same order as the other model endpoints: auth, method, key (or scripted), body.
export async function handleLiveSession(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("live-session", request.method);

  // GPT-Live is the premium option: only a student whose plan has live: true gets past the gate (403 live_not_in_plan).
  const opened = await gate(ctx, request, deps, ["live"], { requireLive: true });
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = LiveSessionRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;
  ctx.note({ sdp_chars: req.sdp.length });

  const resolved = resolveRequestProblem(ctx, deps.env, deps.now?.() ?? new Date(), req);
  if (!resolved.ok) return ctx.fail(resolved.status, resolved.error, resolved.reason, resolved.error);
  const problem = resolved.problem;
  ctx.note(problemFields(problem));

  // Opening a live session is not work by itself, so it charges nothing (reason no_activity_reported); the student's talk is
  // reported later by the app's heartbeat. This still settles the allowance and its notices for the reply.
  await meterActivity(ctx, opened, "live_open");

  // Scripted mode (tests only) has no network and no key, so there is no real session to hand back.
  if (opened.scripted) return ctx.fail(503, "live_unavailable", "scripted_mode_has_no_live_session", "scripted_no_live");

  const cfg = opened.configs.live!;
  const { voice } = liveSettings(deps.env);
  ctx.note({ voice });

  const session = buildLiveSession({ model: cfg.model, voice, instructions: buildLiveInstructions(problem) });
  const gateway = deps.live ?? realLive;
  const created = await gateway.createWebRtcSession({ apiKey: opened.keys.live!, session, sdp: req.sdp });
  if (created.kind === "failed") {
    return ctx.fail(created.status, created.error, created.label, `${created.error}:${created.label}`);
  }

  ctx.note({ live_session: created.sessionId, answer_sdp_chars: created.answerSdp.length });
  return ctx.respond(
    200,
    {
      session_id: created.sessionId,
      sdp: created.answerSdp,
      model: cfg.model,
      voice,
      latency_ms: Date.now() - ctx.startedAt,
    },
    "ok",
    "session_created",
  );
}
