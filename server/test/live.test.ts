import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleHealth } from "../lib/health.js";
import { ALLOWED_CLIENT_EVENTS, handleLiveSession, type LiveCreateResult, type LiveGateway, type LiveSessionConfig } from "../lib/live.js";
import { captureLogs, deps, liveEnv, post, reply, TOKEN } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const OFFER = "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n";
const body = (overrides: Record<string, unknown> = {}) => ({ session_id: "s1", problem_id: "u3-04", sdp: OFFER, ...overrides });

// A fake Live endpoint: records what the server would have sent to OpenAI and returns `result`.
function fakeLive(result: LiveCreateResult = { kind: "created", sessionId: "live_abc123", answerSdp: "v=0\r\nANSWER" }) {
  const calls: { apiKey: string; session: LiveSessionConfig; sdp: string }[] = [];
  const live: LiveGateway = {
    async createWebRtcSession(args) {
      calls.push(args);
      return result;
    },
  };
  return { live, calls };
}
const withLive = (env: Record<string, string | undefined>, live: LiveGateway) => ({ ...deps(env), live });

describe("live-session auth and validation", () => {
  it("answers 401 with no token and a wrong token, and 405 for an authenticated GET", async () => {
    const { live, calls } = fakeLive();
    const d = withLive(liveEnv(), live);
    assert.equal((await handleLiveSession(post("/api/live-session", body(), null), d)).status, 401);
    assert.equal((await handleLiveSession(post("/api/live-session", body(), "nope"), d)).status, 401);
    const get = new Request("https://example.test/api/live-session", { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal((await handleLiveSession(get, d)).status, 405);
    assert.equal(calls.length, 0, "OpenAI is never called without a valid token");
  });

  it("answers 503 naming the OpenAI variable when the key is missing, before reading the body", async () => {
    const r = await reply(await handleLiveSession(post("/api/live-session", {}), deps({ APP_ACCESS_TOKEN: TOKEN })));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "missing_key", "OPENAI_API_KEY is not set"]);
  });

  it("rejects a missing, empty, oversized or non-SDP offer with 422", async () => {
    const { live, calls } = fakeLive();
    const d = withLive(liveEnv(), live);
    for (const sdp of [undefined, "", "hello", "v=0" + "x".repeat(70_000), 42]) {
      const r = await reply(await handleLiveSession(post("/api/live-session", body({ sdp })), d));
      assert.equal(r.status, 422, `sdp ${JSON.stringify(sdp)?.slice(0, 20)}`);
      assert.equal(r.json.error, "invalid_request");
    }
    assert.equal(calls.length, 0);
  });

  it("rejects an unknown problem with 422 and a body that is not JSON with 400", async () => {
    const d = withLive(liveEnv(), fakeLive().live);
    const unknown = await reply(await handleLiveSession(post("/api/live-session", body({ problem_id: "nope-99" })), d));
    assert.deepEqual([unknown.status, unknown.json.error], [422, "unknown_problem"]);
    const bad = new Request("https://example.test/api/live-session", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` }, body: "{nope" });
    assert.equal((await handleLiveSession(bad, d)).status, 400);
  });

  it("scripted mode has no real session to give, so it answers 503 (and never calls OpenAI)", async () => {
    const { live, calls } = fakeLive();
    const r = await reply(await handleLiveSession(post("/api/live-session", body()), withLive({ APP_ACCESS_TOKEN: TOKEN, TUTOR_SCRIPTED: "1" }, live)));
    assert.deepEqual([r.status, r.json.error], [503, "live_unavailable"]);
    assert.equal(calls.length, 0);
  });
});

describe("live-session creates the session", () => {
  it("sends gpt-live-1 with the default voice, client delegation and the five-event allow-list, and returns the answer", async () => {
    const { live, calls } = fakeLive();
    const res = await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv(), live));
    const r = await reply(res);
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.session_id, r.json.sdp, r.json.model, r.json.voice], ["live_abc123", "v=0\r\nANSWER", "gpt-live-1", "meridian"]);
    assert.equal(calls.length, 1);
    const call = calls[0]!;
    assert.equal(call.apiKey, "sk-test-not-real");
    assert.equal(call.sdp, OFFER);
    assert.equal(call.session.model, "gpt-live-1");
    assert.equal(call.session.audio.output.voice, "meridian");
    assert.deepEqual(call.session.delegation, { type: "client" });
    assert.deepEqual([...call.session.client.data_channel.allowed_client_events], [...ALLOWED_CLIENT_EVENTS]);
    assert.equal(ALLOWED_CLIENT_EVENTS.length, 5);
    assert.equal(call.session.client.data_channel.allowed_server_events, "all");
  });

  it("takes LIVE_MODEL and LIVE_VOICE from the environment", async () => {
    const { live, calls } = fakeLive();
    const r = await reply(await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv({ LIVE_MODEL: "gpt-live-2", LIVE_VOICE: "stone" }), live)));
    assert.deepEqual([r.status, r.json.model, r.json.voice], [200, "gpt-live-2", "stone"]);
    assert.deepEqual([calls[0]?.session.model, calls[0]?.session.audio.output.voice], ["gpt-live-2", "stone"]);
  });

  it("gives the voice model the problem statement and the delegation template, but never the worked solution", async () => {
    const { live, calls } = fakeLive();
    await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv(), live));
    const instructions = calls[0]!.session.instructions;
    assert.match(instructions, /Delegation policy:/);
    assert.match(instructions, /Backchannel policy:/);
    assert.match(instructions, /Interruption policy:/);
    assert.match(instructions, /Generate <\|SpawnThinking\|> when:/);
    assert.match(instructions, /Never give the final answer/);
    assert.match(instructions, /The problem on the student's page is: /);
    const { findProblem } = await import("../lib/problems.js");
    const problem = findProblem("u3-04")!;
    assert.ok(instructions.includes(problem.prompt_plain));
    assert.ok(!instructions.includes(problem.final_answer), "the final answer must not reach the voice model");
    for (const step of problem.worked_solution) assert.ok(!instructions.includes(step), `solution step leaked: ${step}`);
  });

  it("answers 502 or 504 with a label and no provider message when OpenAI fails", async () => {
    for (const [failure, status, error] of [
      [{ kind: "failed", status: 502, error: "model_error", label: "provider_http_404" }, 502, "model_error"],
      [{ kind: "failed", status: 504, error: "model_timeout", label: "provider_timeout" }, 504, "model_timeout"],
    ] as const) {
      const r = await reply(await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv(), fakeLive(failure).live)));
      assert.deepEqual([r.status, r.json.error], [status, error]);
      assert.ok(String(r.json.reason).startsWith("provider_"));
    }
  });
});

describe("live-session secrets and logging", () => {
  it("never puts the OpenAI key or the app token in the reply or the log, and logs sizes and ids only", async () => {
    const { live } = fakeLive();
    const res = await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv(), live));
    const text = await res.text();
    for (const secret of ["sk-test-not-real", TOKEN]) assert.ok(!text.includes(secret), `reply must not contain ${secret}`);
    assert.equal(logs.lines.length, 1, "exactly one line per request");
    const line = logs.lines[0]!;
    for (const key of ["request_id", "endpoint", "model", "voice", "sdp_chars", "answer_sdp_chars", "live_session", "latency_ms", "outcome", "status"]) {
      assert.ok(key in line, `log line has ${key}`);
    }
    assert.equal(line.endpoint, "live-session");
    assert.equal(line.outcome, "ok");
    const all = logs.raw.join("\n");
    for (const secret of ["sk-test-not-real", TOKEN, "o=- 4611731400430051336", "ANSWER"]) {
      assert.ok(!all.includes(secret), `log must not contain ${secret}`);
    }
  });

  it("logs a failure with its reason label", async () => {
    const failing = fakeLive({ kind: "failed", status: 502, error: "model_error", label: "provider_http_403" });
    await handleLiveSession(post("/api/live-session", body()), withLive(liveEnv(), failing.live));
    const line = logs.lines[0]!;
    assert.deepEqual([line.status, line.reason, line.outcome], [502, "provider_http_403", "model_error:provider_http_403"]);
  });
});

describe("health reports the live model and voice", () => {
  it("defaults to gpt-live-1 and meridian, and shows overrides", async () => {
    const def = await reply(handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test" }));
    assert.deepEqual((def.json.models as Record<string, unknown>).live, { provider: "openai", model: "gpt-live-1" });
    assert.equal(def.json.live_voice, "meridian");
    const set = await reply(handleHealth(new Request("https://example.test/api/health"), { LIVE_MODEL: "gpt-live-9", LIVE_VOICE: "willow" }));
    assert.deepEqual((set.json.models as Record<string, unknown>).live, { provider: "openai", model: "gpt-live-9" });
    assert.equal(set.json.live_voice, "willow");
    assert.equal(JSON.stringify(def.json).includes("sk-test"), false);
  });
});
