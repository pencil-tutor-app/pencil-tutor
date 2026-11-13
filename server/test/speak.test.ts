import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleHealth } from "../lib/health.js";
import { handleSpeak, SCRIPTED_MP3 } from "../lib/speak.js";
import { captureLogs, deps, fakeSpeech, liveEnv, post, reply, speakBody, TOKEN } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SCRIPTED = { APP_ACCESS_TOKEN: TOKEN, TUTOR_SCRIPTED: "1" };
const FAKE_MP3 = new Uint8Array([0xff, 0xfb, 0x90, 0x00, 1, 2, 3, 4, 5, 6, 7, 8]);

describe("speak auth", () => {
  it("answers 401 with no token, a wrong token, and when the server has no token configured", async () => {
    const d = deps(SCRIPTED);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), null), d)).status, 401);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), "nope"), d)).status, 401);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), TOKEN), deps({ TUTOR_SCRIPTED: "1" }))).status, 401);
    assert.deepEqual(
      logs.lines.map((l) => l.outcome),
      ["unauthorized:missing_header", "unauthorized:bad_token", "unauthorized:token_not_configured"],
    );
  });

  it("answers 401 on an unauthenticated GET, and 405 on an authenticated one", async () => {
    assert.equal((await handleSpeak(new Request("https://example.test/api/speak"), deps(SCRIPTED))).status, 401);
    const get = new Request("https://example.test/api/speak", { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal((await handleSpeak(get, deps(SCRIPTED))).status, 405);
  });
});

describe("speak validation", () => {
  const d = () => deps(SCRIPTED);

  it("rejects empty, blank, missing and over-600-character text with 422", async () => {
    for (const text of ["", "   ", undefined, "x".repeat(601), 42]) {
      const r = await reply(await handleSpeak(post("/api/speak", speakBody({ text })), d()));
      assert.equal(r.status, 422, `text ${JSON.stringify(text)?.slice(0, 20)}`);
      assert.equal(r.json.error, "invalid_request");
    }
  });

  it("accepts text of exactly 1 and exactly 600 characters", async () => {
    for (const text of ["a", "x".repeat(600)]) {
      const res = await handleSpeak(post("/api/speak", speakBody({ text })), d());
      assert.equal(res.status, 200);
    }
  });

  it("rejects a purpose that is not a plain label (so free text cannot reach the logs)", async () => {
    const r = await reply(await handleSpeak(post("/api/speak", speakBody({ purpose: "Student said: help me" })), d()));
    assert.equal(r.status, 422);
  });

  it("answers 400 for a body that is not JSON", async () => {
    const req = new Request("https://example.test/api/speak", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` }, body: "{nope" });
    assert.equal((await handleSpeak(req, d())).status, 400);
  });
});

describe("speak missing key", () => {
  it("answers 503 naming the OpenAI variable, before the body is read", async () => {
    const r = await reply(await handleSpeak(post("/api/speak", {}), deps({ APP_ACCESS_TOKEN: TOKEN })));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "missing_key", "OPENAI_API_KEY is not set"]);
  });
});

describe("speak scripted mode", () => {
  it("returns a small silent mp3 as audio/mpeg with no key and no network", async () => {
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(SCRIPTED));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "audio/mpeg");
    assert.ok(res.headers.get("x-latency-ms") !== null, "X-Latency-Ms is set");
    assert.ok(res.headers.get("x-request-id"));
    const bytes = new Uint8Array(await res.arrayBuffer());
    assert.deepEqual(bytes, SCRIPTED_MP3);
    assert.equal(bytes[0], 0xff, "starts with an MPEG frame sync");
    assert.equal((bytes[1]! & 0xe0), 0xe0);
    assert.equal(bytes.length % 417, 0, "whole frames only");
  });

  it("refuses to turn on in production (503 missing key instead)", async () => {
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps({ ...SCRIPTED, VERCEL_ENV: "production" })));
    assert.deepEqual([r.status, r.json.error], [503, "missing_key"]);
  });
});

describe("speak with a model", () => {
  it("sends the text with the default model, voice, mp3 and instructions, and returns the audio", async () => {
    const { models, calls } = fakeSpeech(FAKE_MP3);
    const res = await handleSpeak(post("/api/speak", speakBody({ text: "Check the signs." })), deps(liveEnv(), models));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "audio/mpeg");
    assert.deepEqual(new Uint8Array(await res.arrayBuffer()), FAKE_MP3);
    assert.equal(calls.length, 1);
    const call = calls[0]!;
    assert.equal(call.model, "gpt-4o-mini-tts");
    assert.equal(call.voice, "coral");
    assert.equal(call.outputFormat, "mp3");
    assert.equal(call.text, "Check the signs.");
    assert.match(String(call.instructions), /patient math tutor talking to a 14-year-old/);
  });

  it("takes SPEAK_MODEL, SPEAK_VOICE and SPEAK_INSTRUCTIONS from the environment", async () => {
    const { models, calls } = fakeSpeech(FAKE_MP3);
    const env = liveEnv({ SPEAK_MODEL: "tts-1-hd", SPEAK_VOICE: "sage", SPEAK_INSTRUCTIONS: "Speak slowly." });
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(env, models));
    assert.equal(res.status, 200);
    assert.deepEqual([calls[0]?.model, calls[0]?.voice, calls[0]?.instructions], ["tts-1-hd", "sage", "Speak slowly."]);
  });

  it("answers 502 when the provider call fails, with a label and no provider message", async () => {
    const { models } = fakeSpeech(() => {
      throw new Error("boom sk-secret-in-message");
    });
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(liveEnv(), models));
    const r = await reply(res);
    assert.deepEqual([r.status, r.json.error], [502, "model_error"]);
    assert.ok(!JSON.stringify(r.json).includes("sk-secret"));
    assert.ok(!logs.raw.join("\n").includes("sk-secret"));
  });

  it("answers 502 when the provider returns no audio bytes", async () => {
    const { models } = fakeSpeech(new Uint8Array(0));
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(liveEnv(), models));
    assert.equal(res.status, 502);
  });
});

describe("speak logging and health", () => {
  it("writes one line with ids, sizes, latency and purpose, never the text or the token", async () => {
    const { models } = fakeSpeech(FAKE_MP3);
    const text = "SECRET-SPOKEN-TEXT about the minus sign";
    await handleSpeak(post("/api/speak", speakBody({ text })), deps(liveEnv(), models));
    await handleSpeak(post("/api/speak", speakBody({ text }), "wrong-token"), deps(liveEnv(), models));
    assert.equal(logs.lines.length, 2, "exactly one line per request");
    const ok = logs.lines[0]!;
    for (const key of ["request_id", "endpoint", "provider", "model", "latency_ms", "text_chars", "audio_bytes", "purpose", "outcome", "status"]) {
      assert.ok(key in ok, `log line has ${key}`);
    }
    assert.equal(ok.endpoint, "speak");
    assert.equal(ok.text_chars, text.length);
    assert.equal(ok.audio_bytes, FAKE_MP3.length);
    assert.equal(ok.purpose, "hint");
    assert.equal(ok.model, "gpt-4o-mini-tts");
    const all = logs.raw.join("\n");
    for (const secret of ["SECRET-SPOKEN", "minus sign", TOKEN, "sk-test-not-real", "wrong-token"]) {
      assert.ok(!all.includes(secret), `log must not contain ${secret}`);
    }
  });

  it("health reports the speak model, default and overridden", async () => {
    const def = await reply(handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test" }));
    assert.deepEqual((def.json.models as Record<string, unknown>).speak, { provider: "openai", model: "gpt-4o-mini-tts" });
    const set = await reply(handleHealth(new Request("https://example.test/api/health"), { SPEAK_MODEL: "tts-1" }));
    assert.deepEqual((set.json.models as Record<string, unknown>).speak, { provider: "openai", model: "tts-1" });
  });
});
