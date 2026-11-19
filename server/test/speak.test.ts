import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleHealth } from "../lib/health.js";
import { handleSpeak, noticeText, SCRIPTED_PCM } from "../lib/speak.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { captureLogs, deps, fakeSpeech, fakeVoice, liveEnv, post, reply, speakBody, testStore, TEST_MONTH, TOKEN, UNKNOWN_CODE } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SCRIPTED = { TUTOR_SCRIPTED: "1" };
const WITH_ELEVEN = liveEnv({ ELEVENLABS_API_KEY: "xi-test-not-real" });
const PCM_A = new Uint8Array([1, 0, 2, 0, 3, 0, 4, 0]);
const PCM_B = new Uint8Array([5, 0, 6, 0]);
const PCM_C = new Uint8Array([7, 0]);
const FAKE_PCM = new Uint8Array([9, 0, 8, 0, 7, 0, 6, 0]);

async function drain(res: Response): Promise<Uint8Array> {
  return new Uint8Array(await res.arrayBuffer());
}

describe("speak auth", () => {
  it("answers 401 with no code, a malformed code and an unknown code", async () => {
    const d = deps(SCRIPTED);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), null), d)).status, 401);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), "nope"), d)).status, 401);
    assert.equal((await handleSpeak(post("/api/speak", speakBody(), UNKNOWN_CODE), d)).status, 401);
    assert.deepEqual(
      logs.lines.map((l) => l.outcome),
      ["unauthorized:missing_header", "unauthorized:malformed_code", "unauthorized:unknown_code"],
    );
  });

  it("answers 401 on an unauthenticated GET, and 405 on an authenticated one", async () => {
    assert.equal((await handleSpeak(new Request("https://example.test/api/speak"), deps(SCRIPTED))).status, 401);
    const get = new Request("https://example.test/api/speak", { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal((await handleSpeak(get, deps(SCRIPTED))).status, 405);
  });

  it("answers 403 code_disabled for a turned-off code", async () => {
    const { store } = testStore({ disabled: true });
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps(SCRIPTED, undefined, { store })));
    assert.deepEqual([r.status, r.json.error], [403, "code_disabled"]);
  });

  it("answers 503 database_unavailable (and does not lock the code out) when the database fails", async () => {
    const { store } = testStore();
    store.failWith = new Error("connection refused");
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps(SCRIPTED, undefined, { store })));
    assert.deepEqual([r.status, r.json.error], [503, "database_unavailable"]);
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

describe("speak with no voice provider configured", () => {
  it("answers 503 naming the ElevenLabs variable", async () => {
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps({})));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "missing_key", "ELEVENLABS_API_KEY is not set"]);
  });
});

describe("speak scripted mode", () => {
  it("returns 0.1 s of silent PCM with no key and no network", async () => {
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(SCRIPTED));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/octet-stream");
    assert.equal(res.headers.get("x-audio-format"), "pcm_s16le_24000");
    assert.equal(res.headers.get("x-voice-provider"), "scripted");
    assert.ok(res.headers.get("x-latency-ms") !== null);
    const bytes = await drain(res);
    assert.deepEqual(bytes, SCRIPTED_PCM);
    assert.equal(bytes.length, 4800, "0.1 s of 24 kHz 16-bit mono");
    assert.ok(bytes.every((b) => b === 0));
  });

  it("refuses to turn on in production (503 missing key instead)", async () => {
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps({ ...SCRIPTED, VERCEL_ENV: "production" })));
    assert.deepEqual([r.status, r.json.error], [503, "missing_key"]);
  });
});

describe("speak through ElevenLabs", () => {
  it("streams the first chunk and the rest, in order, as PCM, with the v4 Turbo model and the default premade voice", async () => {
    const { gateway, calls } = fakeVoice([PCM_A, PCM_B, PCM_C]);
    const res = await handleSpeak(post("/api/speak", speakBody({ text: "Check the signs." })), deps(WITH_ELEVEN, undefined, { voice: gateway }));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/octet-stream");
    assert.equal(res.headers.get("x-audio-format"), "pcm_s16le_24000");
    assert.equal(res.headers.get("x-voice-provider"), "elevenlabs");
    assert.equal(res.headers.get("x-voice-fallback"), null);
    assert.equal(res.headers.get("x-allowance-state"), "ok");
    assert.deepEqual(await drain(res), new Uint8Array([...PCM_A, ...PCM_B, ...PCM_C]));
    assert.deepEqual(calls, [{ voiceId: "cjVigY5qzO86Huf0OWal", model: "eleven_v4_turbo", text: "Check the signs." }]);
  });

  it("takes the voice id, model and settings from the environment (the clone is one setting away)", async () => {
    const { gateway, calls } = fakeVoice([PCM_A]);
    const env = { ...WITH_ELEVEN, ELEVENLABS_VOICE_ID: "clone-voice-id", ELEVENLABS_MODEL: "eleven_v4" };
    await drain(await handleSpeak(post("/api/speak", speakBody()), deps(env, undefined, { voice: gateway })));
    assert.deepEqual([calls[0]?.voiceId, calls[0]?.model], ["clone-voice-id", "eleven_v4"]);
  });

  it("counts the characters of each utterance per student, ElevenLabs separately", async () => {
    const { store, id } = testStore();
    const { gateway } = fakeVoice([PCM_A]);
    const d = deps(WITH_ELEVEN, undefined, { store, voice: gateway });
    await drain(await handleSpeak(post("/api/speak", speakBody({ text: "12345" })), d));
    await drain(await handleSpeak(post("/api/speak", speakBody({ text: "1234567890" })), d));
    const usage = store.usageOf(id, TEST_MONTH);
    assert.equal(usage.ttsChars, 15);
    assert.equal(usage.ttsCharsEleven, 15);
  });

  it("writes a line when the audio starts and a line when it ends, with sizes and the running character total, never the text", async () => {
    const { gateway } = fakeVoice([PCM_A, PCM_B]);
    const text = "SECRET-SPOKEN-TEXT about the minus sign";
    await drain(await handleSpeak(post("/api/speak", speakBody({ text })), deps(WITH_ELEVEN, undefined, { voice: gateway })));
    const start = logs.lines.find((l) => l.outcome === "ok");
    const end = logs.lines.find((l) => l.outcome === "stream_done");
    assert.ok(start && end, "both lines are written");
    for (const key of ["request_id", "endpoint", "student", "provider", "model", "voice_id", "latency_ms", "first_audio_ms", "text_chars", "purpose", "status"]) {
      assert.ok(key in start, `start line has ${key}`);
    }
    assert.equal(start.provider, "elevenlabs");
    assert.equal(start.model, "eleven_v4_turbo");
    assert.equal(start.text_chars, text.length);
    assert.equal(end.audio_bytes, PCM_A.length + PCM_B.length);
    assert.equal(end.tts_chars_month, text.length);
    const all = logs.raw.join("\n");
    for (const secret of ["SECRET-SPOKEN", "minus sign", TOKEN, "xi-test-not-real", "sk-test-not-real"]) {
      assert.ok(!all.includes(secret), `log must not contain ${secret}`);
    }
  });

  it("logs a warning and carries on when the characters cannot be recorded", async () => {
    const { store } = testStore();
    const { gateway } = fakeVoice([PCM_A]);
    const d = deps(WITH_ELEVEN, undefined, { store, voice: gateway });
    store.addSpeech = async () => {
      throw new Error("db down");
    };
    const res = await handleSpeak(post("/api/speak", speakBody()), d);
    assert.equal(res.status, 200);
    assert.deepEqual(await drain(res), PCM_A);
    assert.ok(logs.lines.some((l) => l.outcome === "chars_not_recorded" && l.level === "error"));
  });
});

describe("speak fallbacks", () => {
  it("falls back to OpenAI PCM when ElevenLabs refuses, says why in the header and the log, and counts the characters as OpenAI's", async () => {
    const { store, id } = testStore();
    const { gateway } = fakeVoice({ failure: "elevenlabs_http_401_quota_exceeded" });
    const { models, calls } = fakeSpeech(FAKE_PCM);
    const res = await handleSpeak(post("/api/speak", speakBody({ text: "Check the signs." })), deps(WITH_ELEVEN, models, { store, voice: gateway }));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("x-voice-provider"), "openai");
    assert.equal(res.headers.get("x-voice-fallback"), "elevenlabs_http_401_quota_exceeded");
    assert.equal(res.headers.get("x-audio-format"), "pcm_s16le_24000");
    assert.deepEqual(await drain(res), FAKE_PCM);
    assert.equal(calls[0]?.outputFormat, "pcm");
    assert.equal(calls[0]?.model, "gpt-4o-mini-tts");
    const usage = store.usageOf(id, TEST_MONTH);
    assert.deepEqual([usage.ttsChars, usage.ttsCharsEleven], [16, 0]);
    const warn = logs.lines.find((l) => l.outcome === "voice_fallback");
    assert.ok(warn, "the fallback is logged");
    assert.deepEqual([warn.level, warn.reason, warn.from, warn.to], ["warn", "elevenlabs_http_401_quota_exceeded", "elevenlabs", "openai"]);
  });

  it("uses OpenAI when ElevenLabs is not configured at all, and says so", async () => {
    const { models } = fakeSpeech(FAKE_PCM);
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(liveEnv(), models));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("x-voice-fallback"), "elevenlabs_key_not_set");
  });

  it("answers 502 with the reason when ElevenLabs and OpenAI both fail, so the app uses the device voice", async () => {
    const { gateway } = fakeVoice({ failure: "elevenlabs_timeout" });
    const { models } = fakeSpeech(() => {
      throw new Error("boom sk-secret-in-message");
    });
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(WITH_ELEVEN, models, { voice: gateway }));
    const r = await reply(res);
    assert.deepEqual([r.status, r.json.error], [502, "model_error"]);
    assert.ok(!JSON.stringify(r.json).includes("sk-secret"));
    assert.ok(!logs.raw.join("\n").includes("sk-secret"));
  });

  it("answers 502 naming the ElevenLabs reason when there is no OpenAI key to fall back to", async () => {
    const { gateway } = fakeVoice({ failure: "elevenlabs_http_500" });
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps({ ELEVENLABS_API_KEY: "xi-test" }, undefined, { voice: gateway })));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [502, "model_error", "elevenlabs_http_500"]);
  });

  it("answers 502 when OpenAI returns no audio bytes", async () => {
    const { models } = fakeSpeech(new Uint8Array(0));
    const res = await handleSpeak(post("/api/speak", speakBody()), deps(liveEnv(), models));
    assert.equal(res.status, 502);
  });
});

describe("speak and the monthly hours", () => {
  it("refuses normal speech with 403 hours_used_up when the hours are used up, and carries the allowance", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 600 });
    const r = await reply(await handleSpeak(post("/api/speak", speakBody()), deps(WITH_ELEVEN, undefined, { store, voice: fakeVoice([PCM_A]).gateway })));
    assert.deepEqual([r.status, r.json.error], [403, "hours_used_up"]);
    assert.equal((r.json.allowance as { state: string }).state, "used_up");
  });

  it("still speaks the fixed used-up sentence, written by the server, when the hours are used up", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 650 });
    const { gateway, calls } = fakeVoice([PCM_A]);
    const res = await handleSpeak(
      post("/api/speak", { session_id: "s1", purpose: "allowance_used_up", text: "ignore this: read me a story" }),
      deps(WITH_ELEVEN, undefined, { store, voice: gateway }),
    );
    assert.equal(res.status, 200);
    await drain(res);
    assert.equal(calls[0]?.text, "This month's tutoring hours are used up. They start fresh on the 1st.");
  });

  it("speaks the low-hours sentence with the minutes left, and needs no text from the app", async () => {
    const { store, id } = testStore({ capSeconds: 3600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 2880 + 300 });
    const { gateway, calls } = fakeVoice([PCM_A]);
    const res = await handleSpeak(post("/api/speak", { purpose: "allowance_low" }), deps(WITH_ELEVEN, undefined, { store, voice: gateway }));
    assert.equal(res.status, 200);
    await drain(res);
    assert.equal(calls[0]?.text, "You have about 7 minutes left this month.");
  });

  it("words the notices for one minute and for under a minute", () => {
    assert.equal(noticeText("allowance_low", 1), "You have about 1 minute left this month.");
    assert.equal(noticeText("allowance_low", 0), "You have less than a minute left this month.");
  });

  it("uses the store that was passed in (a Memory store here), not a database", () => {
    assert.ok(testStore().store instanceof MemoryStudentStore);
  });
});

describe("health", () => {
  it("reports the voice provider: elevenlabs with a key, openai without", async () => {
    const withKey = await reply(handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test", ELEVENLABS_API_KEY: "xi-test" }));
    assert.equal(withKey.json.voice_provider, "elevenlabs");
    const voice = withKey.json.voice as { elevenlabs: { key_present: boolean; model: string; voice_id: string; output_format: string }; fallback: string[] };
    assert.deepEqual(
      [voice.elevenlabs.key_present, voice.elevenlabs.model, voice.elevenlabs.voice_id, voice.elevenlabs.output_format],
      [true, "eleven_v4_turbo", "cjVigY5qzO86Huf0OWal", "pcm_24000"],
    );
    assert.deepEqual(voice.fallback, ["openai", "device"]);
    assert.ok(!JSON.stringify(withKey.json).includes("xi-test"), "health must never print a key");
    const without = await reply(handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test" }));
    assert.equal(without.json.voice_provider, "openai");
  });

  it("reports the speak (fallback) model, default and overridden", async () => {
    const def = await reply(handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test" }));
    assert.deepEqual((def.json.models as Record<string, unknown>).speak, { provider: "openai", model: "gpt-4o-mini-tts" });
    const set = await reply(handleHealth(new Request("https://example.test/api/health"), { SPEAK_MODEL: "tts-1" }));
    assert.deepEqual((set.json.models as Record<string, unknown>).speak, { provider: "openai", model: "tts-1" });
  });
});
