import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleConsult, SCRIPTED_CONSULT_ANSWER } from "../lib/consult.js";
import { captureLogs, deps, fakeModels, liveEnv, makePng, post, reply, TOKEN } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SCRIPTED = { APP_ACCESS_TOKEN: TOKEN, TUTOR_SCRIPTED: "1" };
const consultBody = (overrides: Record<string, unknown> = {}) => ({
  session_id: "s1",
  problem_id: "u3-04",
  drawing_revision: 4,
  image_png_base64: makePng(800, 600),
  question: "can you check my second line",
  recent: [{ role: "tutor", text: "Hi, I'm here." }],
  ...overrides,
});

describe("consult auth and validation", () => {
  it("answers 401 without the token, 405 for an authenticated GET, 503 without the key", async () => {
    assert.equal((await handleConsult(post("/api/consult", consultBody(), null), deps(SCRIPTED))).status, 401);
    const get = new Request("https://example.test/api/consult", { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal((await handleConsult(get, deps(SCRIPTED))).status, 405);
    const r = await reply(await handleConsult(post("/api/consult", {}), deps({ APP_ACCESS_TOKEN: TOKEN })));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "missing_key", "OPENAI_API_KEY is not set"]);
  });

  it("rejects a blank question, a too-long question, too many turns and a bad role with 422", async () => {
    const d = () => deps(SCRIPTED);
    const bad: Record<string, unknown>[] = [
      { question: "   " },
      { question: "q".repeat(801) },
      { recent: Array.from({ length: 9 }, () => ({ role: "student", text: "hi" })) },
      { recent: [{ role: "robot", text: "hi" }] },
      { recent: [{ role: "student", text: "t".repeat(401) }] },
    ];
    for (const overrides of bad) {
      const r = await reply(await handleConsult(post("/api/consult", consultBody(overrides)), d()));
      assert.equal(r.status, 422, JSON.stringify(overrides).slice(0, 40));
      assert.equal(r.json.error, "invalid_request");
    }
  });

  it("rejects an oversize image and an unknown problem with 422", async () => {
    const d = () => deps(SCRIPTED);
    const big = await reply(await handleConsult(post("/api/consult", consultBody({ image_png_base64: makePng(800, 600, 410_000) })), d()));
    assert.deepEqual([big.status, big.json.error], [422, "invalid_image"]);
    const unknown = await reply(await handleConsult(post("/api/consult", consultBody({ problem_id: "nope" })), d()));
    assert.deepEqual([unknown.status, unknown.json.error], [422, "unknown_problem"]);
  });
});

describe("consult answers", () => {
  it("scripted mode answers from the script with no key and no network", async () => {
    const r = await reply(await handleConsult(post("/api/consult", consultBody()), deps(SCRIPTED)));
    assert.deepEqual([r.status, r.json.answer_text, r.json.model, r.json.drawing_revision], [200, SCRIPTED_CONSULT_ANSWER, "scripted", 4]);
  });

  it("asks the ask model with the consult policy, the question, the earlier turns and the page, and returns its words", async () => {
    const { models, prompts } = fakeModels("Line one is 2x + 3 = 11. Line two looks unfinished. What did you do to both sides?");
    const r = await reply(await handleConsult(post("/api/consult", consultBody()), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.equal(r.json.answer_text, "Line one is 2x + 3 = 11. Line two looks unfinished. What did you do to both sides?");
    assert.equal(r.json.model, "gpt-6-luna");
    assert.equal(prompts.length, 1);
    const sent = prompts[0]!;
    assert.match(sent, /page reader behind a voice math tutor/);
    assert.match(sent, /can you check my second line/);
    assert.match(sent, /tutor: Hi, I'm here\./);
    assert.match(sent, /Reference worked solution/);
    assert.match(sent, /image\/png/);
  });

  it("answers 502 with a label (no provider message) when the model fails", async () => {
    const { models } = fakeModels(() => {
      throw new Error("boom sk-secret-in-message");
    });
    const r = await reply(await handleConsult(post("/api/consult", consultBody()), deps(liveEnv(), models)));
    assert.deepEqual([r.status, r.json.error], [502, "model_error"]);
    assert.ok(!JSON.stringify(r.json).includes("sk-secret"));
    assert.ok(!logs.raw.join("\n").includes("sk-secret"));
  });

  it("falls back to a plain 'try again' line when the model says nothing", async () => {
    const { models } = fakeModels("   ");
    const r = await reply(await handleConsult(post("/api/consult", consultBody()), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.match(String(r.json.answer_text), /try again/);
    assert.equal(logs.lines.at(-1)?.reason, "empty_answer");
  });
});

describe("consult logging", () => {
  it("writes one line with sizes and counts, never the student's words, the answer, the token or the key", async () => {
    const { models } = fakeModels("SECRET-ANSWER about the minus sign");
    await handleConsult(post("/api/consult", consultBody({ question: "SECRET-QUESTION about line two" })), deps(liveEnv(), models));
    await handleConsult(post("/api/consult", consultBody(), "wrong-token"), deps(liveEnv(), models));
    assert.equal(logs.lines.length, 2, "exactly one line per request");
    const ok = logs.lines[0]!;
    for (const key of ["request_id", "endpoint", "provider", "model", "latency_ms", "image_bytes", "question_chars", "recent_turns", "answer_chars", "outcome", "status"]) {
      assert.ok(key in ok, `log line has ${key}`);
    }
    assert.equal(ok.endpoint, "consult");
    assert.equal(ok.question_chars, "SECRET-QUESTION about line two".length);
    const all = logs.raw.join("\n");
    for (const secret of ["SECRET-ANSWER", "SECRET-QUESTION", "minus sign", TOKEN, "sk-test-not-real", "wrong-token"]) {
      assert.ok(!all.includes(secret), `log must not contain ${secret}`);
    }
  });
});
