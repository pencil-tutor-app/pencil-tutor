import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { afterEach, beforeEach, describe, it } from "node:test";
import { MockLanguageModelV4 } from "ai/test";
import { handleAsk } from "../lib/ask.js";
import { handleConsult } from "../lib/consult.js";
import { finalizeDecision } from "../lib/decision.js";
import { handleHealth } from "../lib/health.js";
import { handleLiveSession, type LiveGateway, type LiveSessionConfig } from "../lib/live.js";
import type { ModelFactory } from "../lib/models.js";
import { buildAskPrompt, buildConsultPrompt, buildLiveInstructions, LIVE_TEACH_NOTE, PRE_ATTEMPT_NOTE, AFTER_ATTEMPT_NOTE } from "../lib/policy.js";
import { findProblem, levelOf, resolveProblem, type Problem } from "../lib/problems.js";
import { acceptReword } from "../lib/record/reword.js";
import { openReference, sealKeyFor, sealReference, SEAL_TTL_MS } from "../lib/seal.js";
import { ANSWER_WITHHELD_TEXT, guardSpokenAnswer, revealsAnswerSpoken, spokenForm } from "../lib/spoken.js";
import { handleTeach, SCRIPTED_FOLLOWUP_ANSWER, SCRIPTED_SOLUTION } from "../lib/teach.js";
import { MESSAGE_BEYOND_COURSE, MESSAGE_NOT_MATH, MESSAGE_OTHER_COURSE } from "../lib/teach-policy.js";
import { resolveRequestProblem } from "../lib/teach-ref.js";
import { RequestCtx } from "../lib/http.js";
import { handleWatch } from "../lib/watch.js";
import { askBody, captureLogs, deps, FIXED_NOW, fakeModels, liveEnv, makePng, post, reply, TEST_MONTH, TOKEN, testStore, watchBody } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const KEY_HEX = randomBytes(32).toString("hex");
const env = (extra: Record<string, string | undefined> = {}) => liveEnv({ TEACH_SEAL_KEY: KEY_HEX, ...extra });
const lastLog = () => logs.lines.at(-1)!;
const eventLogs = (name: string) => logs.lines.filter((l) => l.event === name);

const COURSE = "bc-math-9";
const STATEMENT = "2x + 3 = 11";
const STEPS = ["2x = 11 - 3", "2x = 8", "x = 4"];
const ANSWER = "x = 4";
const SECRET_CONCEPT = "zebra-pattern-concept";

// A fake provider that answers by who is asking (the system prompt names the role) and keeps every call for inspection.
type Call = { role: string; system: string; user: string };
function routed(answers: Partial<Record<string, string | (() => string)>>) {
  const calls: Call[] = [];
  const roleOf = (system: string) =>
    system.includes("You are a careful mathematician") ? "solver"
    : system.includes("You check a worked solution") ? "comparer"
    : system.includes("You write one practice problem") ? "practice"
    : system.includes("You write the full worked solution") ? "solve"
    : system.includes("answering a follow-up question") ? "followup"
    : system.includes("asked to learn a concept") ? "explain"
    : system.includes("page reader behind a voice math tutor") ? "consult"
    : "ask";
  const language = new MockLanguageModelV4({
    doGenerate: async (options) => {
      const system = options.prompt.filter((m) => m.role === "system").map((m) => String(m.content)).join("\n");
      const user = options.prompt
        .filter((m) => m.role === "user")
        .flatMap((m) => (Array.isArray(m.content) ? m.content : []))
        .map((p) => (p.type === "text" ? p.text : ""))
        .join("\n");
      const role = roleOf(system);
      calls.push({ role, system, user });
      const answer = answers[role];
      if (answer === undefined) throw new Error(`no answer set for ${role}`);
      const text = typeof answer === "function" ? answer() : answer;
      return {
        content: [{ type: "text", text }],
        finishReason: { unified: "stop", raw: "stop" },
        usage: { inputTokens: { total: 100, noCache: 100, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 50, text: 50, reasoning: 0 } },
        warnings: [],
      };
    },
  });
  const models: ModelFactory = {
    language: () => language,
    transcription: () => ({
      specificationVersion: "v4",
      provider: "fake",
      modelId: "fake-stt",
      doGenerate: async () => ({ text: "what is the answer", segments: [], language: "en", durationInSeconds: 2, warnings: [], response: { timestamp: new Date(), modelId: "fake-stt" } }),
    }),
    speech: () => {
      throw new Error("no speech model expected");
    },
  };
  return { models, calls };
}

const j = (value: unknown) => JSON.stringify(value);
const LESSON = {
  is_math: true,
  fits_course: true,
  title: "Two-step equations",
  steps: ["Undo the adding first.", "Then undo the multiplying."],
  example: { prompt_plain: "3x + 2 = 14", steps: ["3x = 12", "x = 4"], final_answer: "x = 4" },
  spoken: "Two undoing moves, one at a time.",
};
const PRACTICE = { prompt_plain: STATEMENT, steps: STEPS, final_answer: ANSWER };
const AGREE = j({ equivalent: true, single_answer: true, first_wrong_step: null });
const SOLVED = j({ final_answer: ANSWER });
const teachBody = (overrides: Record<string, unknown> = {}) => ({ action: "explain", session_id: "s1", course: COURSE, concept: "two-step equations", ...overrides });
const LESSON_TEXT = [LESSON.title, ...LESSON.steps].join("\n");
const practiceBody = (overrides: Record<string, unknown> = {}) => teachBody({ action: "practice", lesson_text: LESSON_TEXT, example: LESSON.example, ...overrides });
const run = (body: unknown, models: ModelFactory, e = env(), extra?: Parameters<typeof deps>[2]) => handleTeach(post("/api/teach", body), deps(e, models, extra));

// A sealed reference for the practice problem, as practice would hand it out.
const sealed = (statement = STATEMENT, course = COURSE, at = FIXED_NOW) => sealReference(sealKeyFor(env())!, { course, worked_solution: STEPS, final_answer: ANSWER }, statement, at);
const teachProblem = (): Problem => {
  const r = resolveRequestProblem(new RequestCtx("watch", "POST"), env(), FIXED_NOW, { problem_id: `own:${COURSE}`, problem_text: STATEMENT, problem_ref: sealed() });
  assert.ok(r.ok);
  return r.problem;
};

describe("spoken-form answer check", () => {
  it("reads number words zero to twenty, tens and compounds, and the spoken operators", () => {
    assert.equal(spokenForm("x equals four"), "x=4");
    assert.equal(spokenForm("X = 4"), "x=4");
    assert.equal(spokenForm("x is negative twenty one"), "x=-21");
    assert.equal(spokenForm("x equals minus twenty-one"), "x=-21");
    assert.equal(spokenForm("x equals thirteen"), "x=13");
    assert.equal(spokenForm("three x plus two"), "3x+2");
    assert.equal(spokenForm("x over two"), "x/2");
    assert.equal(spokenForm("x squared times three"), "x^2*3");
    assert.equal(spokenForm("six divided by three"), "6/3");
    assert.equal(spokenForm("x − 4"), "x-4");
  });

  it("catches the answer written and spoken: 'x = 4', 'x equals four', 'x is four', 'the answer is four'", () => {
    for (const text of ["So x = 4.", "so x equals four", "x is four", "X EQUALS FOUR!", "Well, x equals 4 in the end", "the answer is four", "it comes out to x = 4"]) {
      assert.equal(revealsAnswerSpoken(text, "x = 4"), true, text);
    }
  });

  it("lets harmless text through, including other numbers and longer numbers", () => {
    for (const text of ["Undo the adding first.", "x equals fourteen", "x = 45", "x = 4.5", "2x = 8", "two x equals eight", "Try the first step on the page.", "subtract three from both sides", "x = 4x"]) {
      assert.equal(revealsAnswerSpoken(text, "x = 4"), false, text);
    }
  });

  it("the real model's spoken answer is caught: parentheses, prime, squared, cubed, times and number words", () => {
    const spoken = "y prime equals twenty-four x times open parenthesis three x squared minus two close parenthesis cubed.";
    assert.equal(revealsAnswerSpoken(spoken, "y' = 24x(3x^2 - 2)^3"), true);
    assert.equal(revealsAnswerSpoken(spoken, "y' = 24x(3x^2 - 2)^3."), true);
    assert.equal(revealsAnswerSpoken("y prime equals twenty-four x times the quantity three x squared minus two, cubed.", "y' = 24x(3x^2 - 2)^3"), true);
    assert.equal(revealsAnswerSpoken("The modular inverse is three.", "b = 3"), true);
    assert.equal(revealsAnswerSpoken("y prime equals twenty-four x times open parenthesis three x squared minus two close parenthesis to the fourth", "y' = 24x(3x^2 - 2)^3"), false);
    assert.equal(revealsAnswerSpoken("y prime equals twenty-four x left parenthesis three x squared minus two right parenthesis to the third power", "y' = 24x(3x^2 - 2)^3"), true);
    assert.equal(revealsAnswerSpoken("x equals zero point five", "x = 0.5"), true);
    assert.equal(revealsAnswerSpoken("x equals zero point six", "x = 0.5"), false);
    assert.equal(revealsAnswerSpoken("b equals three", "b = 3"), true);
    assert.equal(revealsAnswerSpoken("x equals six", "x = 6"), true);
    assert.equal(revealsAnswerSpoken("the factor is twenty-four x, then the bracket", "y' = 24x(3x^2 - 2)^3"), false);
  });

  it("an answer the model wrote with a closing full stop still matches a sentence without one", () => {
    assert.equal(revealsAnswerSpoken("so y' = 12(2x - 5)^5 is the derivative", "y' = 12(2x - 5)^5."), true);
    assert.equal(revealsAnswerSpoken("so y prime equals twelve", "y' = 12."), true);
    assert.equal(revealsAnswerSpoken("so y prime equals thirteen", "y' = 12."), false);
    assert.equal(revealsAnswerSpoken("the answer is four", "x = 4."), true);
  });

  it("an empty answer never matches, and negative and fractional answers are read the same way", () => {
    assert.equal(revealsAnswerSpoken("anything", ""), false);
    assert.equal(revealsAnswerSpoken("x equals negative two", "x = -2"), true);
    assert.equal(revealsAnswerSpoken("x equals minus two", "x = −2"), true);
    assert.equal(revealsAnswerSpoken("x equals three over four", "x = 3/4"), true);
    assert.equal(revealsAnswerSpoken("x equals three over five", "x = 3/4"), false);
  });

  it("guardSpokenAnswer replaces a leak for a teach problem and leaves bank and own problems alone", () => {
    const teach = teachProblem();
    assert.deepEqual(guardSpokenAnswer(teach, "so x equals four"), { text: ANSWER_WITHHELD_TEXT, withheld: true });
    assert.deepEqual(guardSpokenAnswer(teach, "undo the adding"), { text: "undo the adding", withheld: false });
    const own = resolveProblem("own:bc-math-9", STATEMENT);
    assert.ok(own.ok);
    assert.equal(guardSpokenAnswer(own.problem, "x equals four").withheld, false);
  });
});

describe("seal", () => {
  const key = sealKeyFor(env())!;
  const ref = { course: COURSE, worked_solution: STEPS, final_answer: ANSWER };
  const sealedBack = { ...ref, prompt_plain: STATEMENT };

  it("round trips the solution and answer, and never shows them in the token", () => {
    const token = sealReference(key, ref, STATEMENT, FIXED_NOW);
    const opened = openReference(key, token, { course: COURSE, promptPlain: STATEMENT }, FIXED_NOW);
    assert.deepEqual(opened, { ok: true, reference: sealedBack });
    assert.ok(!Buffer.from(token.split(".")[1]!, "base64url").toString("utf8").includes("2x = 8"));
    assert.notEqual(sealReference(key, ref, STATEMENT, FIXED_NOW), token, "a fresh nonce each time");
  });

  it("rejects a tampered token, a token under another key, junk, another course, another statement", () => {
    const token = sealReference(key, ref, STATEMENT, FIXED_NOW);
    const bytes = Buffer.from(token.split(".")[1]!, "base64url");
    bytes[bytes.length - 1] = (bytes.at(-1) ?? 0) ^ 1;
    const open = (t: string, k = key, course = COURSE, text = STATEMENT) => openReference(k, t, { course, promptPlain: text }, FIXED_NOW);
    assert.deepEqual(open(`t1.${bytes.toString("base64url")}`), { ok: false, label: "bad_seal" });
    assert.deepEqual(open(token, randomBytes(32)), { ok: false, label: "bad_seal" });
    assert.deepEqual(open("junk"), { ok: false, label: "malformed" });
    assert.deepEqual(open("t1.AAAA"), { ok: false, label: "malformed" });
    assert.deepEqual(open(token, key, "calculus-1"), { ok: false, label: "wrong_course" });
    assert.deepEqual(open(token, key, COURSE, "2x + 3 = 13"), { ok: false, label: "text_mismatch" });
    assert.deepEqual(open(token, key, COURSE, "  2x   +  3 = 11 \n"), { ok: true, reference: sealedBack }, "spacing does not matter");
    assert.deepEqual(openReference(key, token, { course: COURSE }, FIXED_NOW), { ok: true, reference: sealedBack }, "no statement sent: the sealed one is used");
  });

  it("expires after 7 days", () => {
    const token = sealReference(key, ref, STATEMENT, FIXED_NOW);
    const at = (ms: number) => openReference(key, token, { course: COURSE, promptPlain: STATEMENT }, new Date(FIXED_NOW.getTime() + ms));
    assert.equal(at(SEAL_TTL_MS - 1000).ok, true);
    assert.deepEqual(at(SEAL_TTL_MS + 1000), { ok: false, label: "expired" });
  });

  it("the key is 32 bytes as hex or base64; scripted mode has a fixed one, production never", () => {
    assert.equal(sealKeyFor({ TEACH_SEAL_KEY: KEY_HEX })?.length, 32);
    assert.equal(sealKeyFor({ TEACH_SEAL_KEY: randomBytes(32).toString("base64") })?.length, 32);
    assert.equal(sealKeyFor({ TEACH_SEAL_KEY: "too short" }), null);
    assert.equal(sealKeyFor({}), null);
    assert.equal(sealKeyFor({ TUTOR_SCRIPTED: "1" })?.length, 32);
    assert.equal(sealKeyFor({ TUTOR_SCRIPTED: "1", VERCEL_ENV: "production" }), null);
  });
});

describe("a sealed reference on watch, ask, consult and live-session", () => {
  const watchWith = (extra: Record<string, unknown>) => watchBody({ problem_id: `own:${COURSE}`, problem_text: STATEMENT, ...extra });
  const wait = j({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null });

  it("resolves to a teach problem: reference branch, the course's tier, the answer in hand", () => {
    const p = teachProblem();
    assert.deepEqual([p.teach, p.own, p.final_answer, p.worked_solution, p.course], [true, undefined, ANSWER, STEPS, COURSE]);
    assert.equal(levelOf(p), "high_school");
  });

  it("watch: the model gets the reference solution, log says teach and accepted, nothing readable is logged", async () => {
    const fake = fakeModels(wait);
    const r = await reply(await handleWatch(post("/api/watch", watchWith({ problem_ref: sealed() })), deps(env(), fake.models)));
    assert.equal(r.status, 200);
    assert.match(fake.prompts[0]!, /Reference worked solution/);
    assert.match(fake.prompts[0]!, /Final answer: x = 4/);
    assert.doesNotMatch(fake.prompts[0]!, /no reference solution/);
    assert.equal(r.json.model, "gpt-6-luna");
    assert.deepEqual([lastLog().problem_kind, lastLog().reference, lastLog().tier], ["teach", "accepted", "standard"]);
    assert.ok(!logs.raw.join("\n").includes("2x = 8"));
  });

  it("watch: an interrupt whose hint says the answer in words is dropped (the spoken-form check)", async () => {
    const leak = j({ action: "interrupt", line: 2, reason: "slip", hint_spoken: "Careful: x equals four.", hint_written: "Check the sign" });
    const fake = fakeModels(leak);
    const r = await reply(await handleWatch(post("/api/watch", watchWith({ problem_ref: sealed() })), deps(env(), fake.models)));
    assert.deepEqual([r.json.action, lastLog().reason_label], ["wait", "hint_reveals_answer"]);
    const lines = [1, 2].map((index) => ({ index, box: { x: 0, y: 0, w: 1, h: 1 } }));
    const decision = { action: "interrupt", line: 2, reason: "slip", hint_spoken: "Check the sign on that line.", hint_written: "Check the sign" };
    assert.equal(finalizeDecision(decision, lines, teachProblem()).label, "model_interrupt");
    assert.equal(acceptReword("So x equals four.", teachProblem()).ok, false);
    assert.equal(acceptReword("Look at the sign.", teachProblem()).ok, true);
  });

  it("an expired, tampered, other-course or other-text reference is 422 practice_expired, never an own problem, and no model is called", async () => {
    const fake = fakeModels(wait);
    const cases: [string, Record<string, unknown>][] = [
      ["expired", { problem_ref: sealed(STATEMENT, COURSE, new Date(FIXED_NOW.getTime() - SEAL_TTL_MS - 1000)) }],
      ["bad_seal", { problem_ref: sealed().slice(0, -3) + "AAA" }],
      ["malformed", { problem_ref: "junk" }],
      ["wrong_course", { problem_ref: sealed(STATEMENT, "calculus-1") }],
      ["text_mismatch", { problem_text: "2x + 3 = 13" }],
    ];
    for (const [label, extra] of cases) {
      const body = watchWith({ problem_ref: sealed(), ...extra });
      const r = await reply(await handleWatch(post("/api/watch", body), deps(env(), fake.models)));
      assert.deepEqual([r.status, r.json.error, r.json.reason], [422, "practice_expired", `reference_${label}`], label);
      assert.equal(lastLog().reference, `rejected_${label}`);
    }
    const bank = await reply(await handleWatch(post("/api/watch", watchBody({ problem_ref: sealed() })), deps(env(), fake.models)));
    assert.deepEqual([bank.status, bank.json.error], [422, "practice_expired"], "a reference on a bank id is refused");
    assert.equal(fake.prompts.length, 0);
  });

  it("the statement is inside the seal: the id and the token are enough, and a statement that is sent must still match", async () => {
    const fake = fakeModels(wait);
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: `own:${COURSE}`, problem_ref: sealed() })), deps(env(), fake.models)));
    assert.equal(r.status, 200);
    assert.match(fake.prompts[0]!, /The problem the student is solving: 2x \+ 3 = 11/);
    assert.match(fake.prompts[0]!, /Final answer: x = 4/);
    assert.equal(lastLog().reference, "accepted");
    const unknownCourse = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "own:nope", problem_ref: sealed() })), deps(env(), fake.models)));
    assert.deepEqual([unknownCourse.status, unknownCourse.json.error], [422, "unknown_course"]);
  });

  it("with no key on the server a reference is 503 teach_unavailable", async () => {
    const fake = fakeModels(wait);
    const r = await reply(await handleWatch(post("/api/watch", watchWith({ problem_ref: sealed() })), deps(liveEnv(), fake.models)));
    assert.deepEqual([r.status, r.json.error], [503, "teach_unavailable"]);
  });

  it("no reference at all stays an own problem, as before", async () => {
    const fake = fakeModels(wait);
    await handleWatch(post("/api/watch", watchWith({})), deps(env(), fake.models));
    assert.match(fake.prompts[0]!, /no reference solution/);
    assert.equal(lastLog().problem_kind, "own");
    assert.equal(lastLog().reference, undefined);
  });

  it("consult and ask accept the reference; live-session accepts it and refuses a bad one before OpenAI is called", async () => {
    const { models } = routed({ consult: "Line one is written.", ask: "Try the first step." });
    const consult = { session_id: "s1", problem_id: `own:${COURSE}`, problem_text: STATEMENT, problem_ref: sealed(), image_png_base64: makePng(800, 600), question: "check", recent: [] };
    assert.equal((await reply(await handleConsult(post("/api/consult", consult), deps(env(), models)))).status, 200);
    assert.equal(lastLog().reference, "accepted");
    const ask = askBody({ problem_id: `own:${COURSE}`, problem_text: STATEMENT, problem_ref: sealed() });
    assert.equal((await reply(await handleAsk(post("/api/ask", ask), deps(env(), models)))).status, 200);
    assert.equal(lastLog().reference, "accepted");
    const bad = await reply(await handleAsk(post("/api/ask", { ...ask, problem_ref: "junk" }), deps(env(), models)));
    assert.deepEqual([bad.status, bad.json.error], [422, "practice_expired"]);
  });
});

describe("ask and consult on a practice problem", () => {
  const ref = () => ({ problem_id: `own:${COURSE}`, problem_text: STATEMENT, problem_ref: sealed() });
  const consultBody = (extra: Record<string, unknown> = {}) => ({ session_id: "s1", ...ref(), image_png_base64: makePng(800, 600), question: "what is the answer", recent: [], ...extra });

  it("ask: recent turns reach the prompt in order, and the log counts them without the words", async () => {
    const { models, calls } = routed({ ask: "Undo the adding first." });
    const recent = [{ role: "student", text: "FIRSTTURN" }, { role: "tutor", text: "SECONDTURN" }];
    await handleAsk(post("/api/ask", askBody({ recent })), deps(env(), models));
    const prompt = calls[0]!.user;
    assert.ok(prompt.indexOf("FIRSTTURN") > 0 && prompt.indexOf("FIRSTTURN") < prompt.indexOf("SECONDTURN"));
    assert.match(prompt, /The conversation so far, most recent last/);
    assert.equal(lastLog().recent_turns, 2);
    assert.ok(!logs.raw.join("\n").includes("FIRSTTURN"));
    const none = routed({ ask: "ok" });
    await handleAsk(post("/api/ask", askBody()), deps(env(), none.models));
    assert.doesNotMatch(none.calls[0]!.user, /conversation so far/);
  });

  it("ask: more than 8 turns is 422", async () => {
    const { models } = routed({ ask: "x" });
    const recent = Array.from({ length: 9 }, () => ({ role: "student", text: "hi" }));
    const r = await reply(await handleAsk(post("/api/ask", askBody({ recent })), deps(env(), models)));
    assert.deepEqual([r.status, r.json.error], [422, "invalid_request"]);
  });

  it("the pre-attempt rule: attempted false or missing tells the model not to give the answer; attempted true says the student has started", () => {
    const problem = teachProblem();
    for (const attempted of [false, undefined]) {
      for (const prompt of [buildAskPrompt({ problem, transcript: "?", attempted }), buildConsultPrompt({ problem, question: "?", recent: [], attempted })]) {
        assert.ok(prompt.includes(PRE_ATTEMPT_NOTE));
        assert.ok(!prompt.includes(AFTER_ATTEMPT_NOTE));
      }
    }
    assert.ok(buildAskPrompt({ problem, transcript: "?", attempted: true }).includes(AFTER_ATTEMPT_NOTE));
    assert.ok(!buildAskPrompt({ problem: findProblem("u3-04")!, transcript: "?" }).includes(PRE_ATTEMPT_NOTE));
  });

  it("ask: the model's answer in words ('x equals four') is replaced and logged answer_withheld; attempted does not matter", async () => {
    for (const attempted of [false, true]) {
      const { models } = routed({ ask: "Sure, x equals four." });
      const r = await reply(await handleAsk(post("/api/ask", askBody({ ...ref(), attempted })), deps(env(), models)));
      assert.equal(r.json.answer_text, ANSWER_WITHHELD_TEXT);
      assert.deepEqual([lastLog().answer_withheld, lastLog().reason], [true, "answer_withheld"]);
    }
    const { models } = routed({ ask: "Undo the adding first." });
    const ok = await reply(await handleAsk(post("/api/ask", askBody(ref())), deps(env(), models)));
    assert.equal(ok.json.answer_text, "Undo the adding first.");
  });

  it("consult: the same replacement, and the attempted flag reaches the prompt", async () => {
    const { models, calls } = routed({ consult: "The answer is four." });
    const r = await reply(await handleConsult(post("/api/consult", consultBody({ attempted: false })), deps(env(), models)));
    assert.equal(r.json.answer_text, ANSWER_WITHHELD_TEXT);
    assert.ok(calls[0]!.user.includes(PRE_ATTEMPT_NOTE));
    assert.equal(lastLog().answer_withheld, true);
    const after = routed({ consult: "Line one is right." });
    await handleConsult(post("/api/consult", consultBody({ attempted: true })), deps(env(), after.models));
    assert.ok(after.calls[0]!.user.includes(AFTER_ATTEMPT_NOTE));
  });

  it("a bank problem answer that says its answer is not touched (the guard is for practice problems)", async () => {
    const { models } = routed({ ask: "Well, x equals four." });
    const r = await reply(await handleAsk(post("/api/ask", askBody()), deps(env(), models)));
    assert.equal(r.json.answer_text, "Well, x equals four.");
  });
});

describe("live-session on a practice problem", () => {
  const OFFER = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n";
  const withLive = (live: LiveGateway, e = env()) => ({ ...deps(e, undefined, { store: testStore({ planLive: true }).store }), live });
  const fakeLive = () => {
    const calls: LiveSessionConfig[] = [];
    const live: LiveGateway = { async createWebRtcSession(args) { calls.push(args.session); return { kind: "created", sessionId: "live_abc", answerSdp: "v=0\r\nANSWER" }; } };
    return { live, calls };
  };
  const body = (extra: Record<string, unknown> = {}) => ({ session_id: "s1", problem_id: `own:${COURSE}`, problem_text: STATEMENT, problem_ref: sealed(), sdp: OFFER, ...extra });

  it("the voice instructions carry the pre-attempt rule and the statement, and never the solution or the answer", async () => {
    const { live, calls } = fakeLive();
    const r = await reply(await handleLiveSession(post("/api/live-session", body()), withLive(live)));
    assert.equal(r.status, 200);
    const text = calls[0]!.instructions;
    assert.ok(text.includes(LIVE_TEACH_NOTE));
    assert.ok(text.includes(`The problem on the student's page is: ${STATEMENT}`));
    for (const secret of [ANSWER, "2x = 8", "2x = 11 - 3", "Reference worked solution"]) assert.ok(!text.includes(secret), secret);
    assert.match(LIVE_TEACH_NOTE, /Never say its final answer/);
    assert.match(LIVE_TEACH_NOTE, /in digits or in words/);
    assert.match(LIVE_TEACH_NOTE, /Until a look at the page shows/);
    assert.match(LIVE_TEACH_NOTE, /worked solution is on their screen/);
    assert.deepEqual([lastLog().problem_kind, lastLog().reference], ["teach", "accepted"]);
    assert.ok(!buildLiveInstructions(teachProblem()).includes(ANSWER));
  });

  it("a bank or own problem has no teach note, and a bad or expired reference is 422 with OpenAI never called", async () => {
    const { live, calls } = fakeLive();
    const own = await reply(await handleLiveSession(post("/api/live-session", body({ problem_ref: undefined })), withLive(live)));
    assert.equal(own.status, 200);
    assert.ok(!calls[0]!.instructions.includes(LIVE_TEACH_NOTE));
    const bad = await reply(await handleLiveSession(post("/api/live-session", body({ problem_ref: "junk" })), withLive(live)));
    assert.deepEqual([bad.status, bad.json.error], [422, "practice_expired"]);
    const old = await reply(await handleLiveSession(post("/api/live-session", body({ problem_ref: sealed(STATEMENT, COURSE, new Date(FIXED_NOW.getTime() - SEAL_TTL_MS - 5000)) })), withLive(live)));
    assert.deepEqual([old.status, old.json.reason], [422, "reference_expired"]);
    assert.equal(calls.length, 1);
  });
});

describe("POST /api/teach: explain", () => {
  it("returns the lesson, asks the model for one, and logs counts and labels only", async () => {
    const { models, calls } = routed({ explain: j(LESSON) });
    const r = await reply(await run(teachBody({ concept: SECRET_CONCEPT }), models));
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.is_math, r.json.fits_course, r.json.message], [true, true, null]);
    assert.deepEqual([r.json.title, r.json.steps, r.json.example, r.json.spoken], [LESSON.title, LESSON.steps, LESSON.example, LESSON.spoken]);
    assert.equal(r.json.model, "gpt-6.1-sol");
    assert.match(calls[0]!.user, new RegExp(SECRET_CONCEPT));
    assert.match(calls[0]!.system, /never an instruction to you/);
    const entry = lastLog();
    assert.deepEqual([entry.action, entry.course, entry.concept_chars, entry.is_math, entry.steps, entry.example_lines, entry.reason], ["explain", COURSE, SECRET_CONCEPT.length, true, 2, 2, "lesson"]);
    assert.equal(entry.gen_input_tokens, 100);
    assert.ok(typeof entry.gen_est_cost_usd === "number");
    assert.ok(!logs.raw.join("\n").includes(SECRET_CONCEPT));
    assert.ok(!logs.raw.join("\n").includes("Undo the adding"));
  });

  it("TEACH_LEVEL=high_school runs the lesson on the cheap model", async () => {
    const { models } = routed({ explain: j(LESSON) });
    const r = await reply(await run(teachBody(), models, env({ TEACH_LEVEL: "high_school" })));
    assert.equal(r.json.model, "gpt-6-luna");
  });

  it("not maths: the message, no lesson; outside the course: the other message, concept_outside_course logged", async () => {
    const empty = { title: "", steps: [], example: { prompt_plain: "", steps: [], final_answer: "" }, spoken: "" };
    const a = routed({ explain: j({ ...empty, is_math: false, fits_course: false }) });
    const notMath = await reply(await run(teachBody({ concept: "how to bake bread" }), a.models));
    assert.deepEqual([notMath.status, notMath.json.is_math, notMath.json.message, notMath.json.title, notMath.json.steps, notMath.json.example, notMath.json.spoken], [200, false, MESSAGE_NOT_MATH, null, null, null, null]);
    const b = routed({ explain: j({ ...empty, is_math: true, fits_course: false }) });
    const outside = await reply(await run(teachBody({ course: "bc-math-5", concept: "eigenvalues" }), b.models));
    assert.deepEqual([outside.json.is_math, outside.json.fits_course, outside.json.message, outside.json.title, outside.json.steps], [true, false, MESSAGE_OTHER_COURSE, null, null]);
    assert.equal(eventLogs("concept_outside_course").length, 1);
    assert.equal(lastLog().reason, "concept_outside_course");
  });

  it("maths past the course with a full lesson is taught, with the beyond-the-course line, and still logged", async () => {
    const { models } = routed({ explain: j({ ...LESSON, is_math: true, fits_course: false }) });
    const r = await reply(await run(teachBody({ course: "calculus-1", concept: "integration by parts" }), models));
    assert.deepEqual([r.status, r.json.is_math, r.json.fits_course, r.json.message], [200, true, false, MESSAGE_BEYOND_COURSE]);
    assert.equal(r.json.title, LESSON.title);
    assert.deepEqual(r.json.steps, LESSON.steps);
    assert.equal(eventLogs("concept_outside_course").length, 1);
    assert.equal(lastLog().reason, "lesson_beyond_course");
  });

  it("an answer over a schema limit is a failed call: 502 teach_too_long, nothing trimmed", async () => {
    const long = { ...LESSON, steps: ["a", "b", "c", "d", "e"] };
    const { models } = routed({ explain: j(long) });
    const r = await reply(await run(teachBody(), models));
    assert.deepEqual([r.status, r.json.error, r.json.title], [502, "teach_too_long", undefined]);
    assert.equal(eventLogs("teach_too_long").length, 1);
    const longLine = routed({ explain: j({ ...LESSON, example: { ...LESSON.example, steps: ["x".repeat(161)] } }) });
    assert.equal((await reply(await run(teachBody(), longLine.models))).json.error, "teach_too_long");
    const unreadable = routed({ explain: "not json at all" });
    assert.equal((await reply(await run(teachBody(), unreadable.models))).json.error, "teach_unusable");
    const hollow = routed({ explain: j({ ...LESSON, steps: [] }) });
    assert.equal((await reply(await run(teachBody(), hollow.models))).json.error, "teach_unusable");
  });

  it("422 for an unknown course, a blank concept, a concept over 200 characters, an unknown action; the model is never called", async () => {
    const { models, calls } = routed({ explain: j(LESSON) });
    const unknown = await reply(await run(teachBody({ course: "nope" }), models));
    assert.deepEqual([unknown.status, unknown.json.error], [422, "unknown_course"]);
    for (const body of [teachBody({ concept: "  " }), teachBody({ concept: "x".repeat(201) }), teachBody({ action: "lecture" }), teachBody({ concept: 5 })]) {
      const r = await reply(await run(body, models));
      assert.deepEqual([r.status, r.json.error], [422, "invalid_request"], JSON.stringify(body).slice(0, 60));
    }
    assert.equal((await reply(await run(teachBody({ concept: "x".repeat(200) }), models))).status, 200);
    assert.equal(calls.length, 1);
  });

  it("is metered as a question, and hours used up blocks it", async () => {
    const { models } = routed({ explain: j(LESSON) });
    const store = testStore();
    await run(teachBody(), models, env(), { store: store.store });
    assert.equal(lastLog().counted_kind, "question");
    const spent = testStore({ capSeconds: 600 });
    spent.store.setUsage(spent.id, TEST_MONTH, { countedSeconds: 600 });
    const blocked = await reply(await run(teachBody(), models, env(), { store: spent.store }));
    assert.deepEqual([blocked.status, blocked.json.error], [403, "hours_used_up"]);
  });

  it("scripted mode answers without a key, and a bad method or code is refused like every endpoint", async () => {
    const r = await reply(await handleTeach(post("/api/teach", teachBody()), deps({ TUTOR_SCRIPTED: "1" })));
    assert.deepEqual([r.status, r.json.model], [200, "scripted"]);
    const noCode = await reply(await handleTeach(post("/api/teach", teachBody(), null), deps(env())));
    assert.equal(noCode.status, 401);
    const get = await reply(await handleTeach(new Request("https://example.test/api/teach", { method: "GET", headers: { authorization: "Bearer K7MQ2XAB" } }), deps(env())));
    assert.equal(get.status, 405);
  });
});

describe("POST /api/teach: followup", () => {
  const body = (extra: Record<string, unknown> = {}) => teachBody({ action: "followup", lesson_text: "Two-step equations. Undo the adding first.", recent: [], question: "why adding first?", ...extra });

  it("answers a typed question and sends the last turns in order", async () => {
    const recent = [{ role: "student", text: "TURNONE" }, { role: "tutor", text: "TURNTWO" }];
    const { models, calls } = routed({ followup: j({ answer_text: "Because the adding sits outside the multiplying." }) });
    const r = await reply(await run(body({ recent, concept: SECRET_CONCEPT }), models));
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.transcript, r.json.answer_text], [null, "Because the adding sits outside the multiplying."]);
    const prompt = calls[0]!.user;
    assert.ok(prompt.indexOf("TURNONE") < prompt.indexOf("TURNTWO") && prompt.indexOf("TURNTWO") < prompt.indexOf("why adding first?"));
    assert.match(prompt, /Undo the adding first/);
    const entry = lastLog();
    assert.deepEqual([entry.recent_turns, entry.input, entry.question_chars, entry.reason], [2, "typed", "why adding first?".length, "answered"]);
    assert.ok(!logs.raw.join("\n").includes("TURNONE"));
    assert.ok(!logs.raw.join("\n").includes("why adding first"));
  });

  it("more than 8 turns, a turn over 400 characters, both or neither of question and audio: 422", async () => {
    const { models } = routed({ followup: j({ answer_text: "x" }) });
    const turns = (n: number, text = "hi") => Array.from({ length: n }, () => ({ role: "student", text }));
    for (const extra of [{ recent: turns(9) }, { recent: turns(1, "x".repeat(401)) }, { audio_base64: "AAAA" }, { question: undefined }, { question: "  " }]) {
      const r = await reply(await run(body(extra), models));
      assert.deepEqual([r.status, r.json.error], [422, "invalid_request"], JSON.stringify(extra).slice(0, 50));
    }
    assert.equal((await reply(await run(body({ recent: turns(8, "x".repeat(400)) }), models))).status, 200);
  });

  it("a spoken question goes through transcription and the transcript comes back", async () => {
    const { models, calls } = routed({ followup: j({ answer_text: "Because it undoes the order." }) });
    const r = await reply(await run(body({ question: undefined, audio_base64: Buffer.from("fake m4a").toString("base64") }), models));
    assert.deepEqual([r.status, r.json.transcript, r.json.answer_text], [200, "what is the answer", "Because it undoes the order."]);
    assert.match(calls[0]!.user, /what is the answer/);
    assert.equal(lastLog().input, "voice");
    assert.ok(!logs.raw.join("\n").includes("what is the answer"));
  });

  it("with the practice reference the answer guard works: 'x equals four' is replaced and logged answer_withheld", async () => {
    const { models, calls } = routed({ followup: j({ answer_text: "Just so you know, x equals four." }) });
    const withRef = body({ problem_text: STATEMENT, problem_ref: sealed(), question: "what is the answer?", attempted: false });
    const r = await reply(await run(withRef, models));
    assert.equal(r.json.answer_text, ANSWER_WITHHELD_TEXT);
    assert.deepEqual([lastLog().answer_withheld, lastLog().reason, lastLog().problem_kind], [true, "answer_withheld", "teach"]);
    assert.equal(eventLogs("answer_withheld").length, 1);
    assert.ok(calls[0]!.user.includes(PRE_ATTEMPT_NOTE));
    assert.match(calls[0]!.user, /Reference worked solution/);
    const expired = await reply(await run(body({ problem_text: STATEMENT, problem_ref: "junk" }), models));
    assert.deepEqual([expired.status, expired.json.error], [422, "practice_expired"]);
  });

  it("the reference alone is enough for the guard (the statement is sealed in it)", async () => {
    const { models } = routed({ followup: j({ answer_text: "x equals four." }) });
    const r = await reply(await run(body({ problem_ref: sealed(), attempted: true }), models));
    assert.deepEqual([r.json.answer_text, lastLog().reference], [ANSWER_WITHHELD_TEXT, "accepted"]);
  });

  it("without a reference nothing is withheld (a lesson question about the example may say its answer)", async () => {
    const { models } = routed({ followup: j({ answer_text: "In the example x equals four." }) });
    const r = await reply(await run(body(), models));
    assert.equal(r.json.answer_text, "In the example x equals four.");
  });

  it("an answer over 700 characters is teach_too_long", async () => {
    const { models } = routed({ followup: j({ answer_text: "w".repeat(701) }) });
    const r = await reply(await run(body(), models));
    assert.deepEqual([r.status, r.json.error], [502, "teach_too_long"]);
  });

  it("scripted mode answers without a key", async () => {
    const r = await reply(await handleTeach(post("/api/teach", body()), deps({ TUTOR_SCRIPTED: "1" })));
    assert.deepEqual([r.status, r.json.answer_text], [200, SCRIPTED_FOLLOWUP_ANSWER]);
  });
});

describe("POST /api/teach: practice and the two-call check", () => {
  const agree = { practice: j(PRACTICE), solver: SOLVED, comparer: AGREE };

  it("both calls agree: the problem and a sealed reference come back, and the reference opens to the checked solution", async () => {
    const { models, calls } = routed(agree);
    const r = await reply(await run(practiceBody(), models));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.problem, { id: `own:${COURSE}`, prompt_plain: STATEMENT });
    assert.deepEqual([r.json.example_checked, r.json.reason], [true, null]);
    const opened = openReference(sealKeyFor(env())!, r.json.problem_ref as string, { course: COURSE, promptPlain: STATEMENT }, FIXED_NOW);
    assert.deepEqual(opened, { ok: true, reference: { course: COURSE, worked_solution: STEPS, final_answer: ANSWER, prompt_plain: STATEMENT } });
    assert.ok(!JSON.stringify(r.json).includes("2x = 8"), "the reply carries no readable solution");
    assert.deepEqual(calls.map((c) => c.role).sort(), ["comparer", "comparer", "practice", "solver", "solver"]);
    const entry = lastLog();
    assert.deepEqual([entry.checker, entry.example_check, entry.reference, entry.reason, entry.check_model], ["agree", "agree", "sealed", "practice_checked", "gpt-6.1-sol"]);
    assert.ok(typeof entry.est_cost_usd === "number" && entry.est_cost_usd > 0);
    assert.ok(typeof entry.check_solve_input_tokens === "number");
    const text = logs.raw.join("\n");
    for (const secret of [STATEMENT, "2x = 8", "Undo the adding"]) assert.ok(!text.includes(secret), secret);
  });

  it("a closing full stop on the generated answer is dropped before the check and the seal", async () => {
    const { models, calls } = routed({ practice: j({ ...PRACTICE, final_answer: "x = 4." }), solver: SOLVED, comparer: AGREE });
    const r = await reply(await run(practiceBody(), models));
    const opened = openReference(sealKeyFor(env())!, r.json.problem_ref as string, { course: COURSE, promptPlain: STATEMENT }, FIXED_NOW);
    assert.deepEqual(opened.ok && opened.reference.final_answer, "x = 4");
    assert.ok(calls.some((c) => c.role === "comparer" && c.user.includes("Proposed final answer: x = 4\n")));
  });

  it("call 1 is blind: the solver sees the statement and nothing else; the comparer sees the steps and both answers", async () => {
    const { models, calls } = routed(agree);
    await run(practiceBody(), models);
    const solverPrompts = calls.filter((c) => c.role === "solver").map((c) => c.user);
    assert.deepEqual(solverPrompts.sort(), [`Problem: ${LESSON.example.prompt_plain}`, `Problem: ${STATEMENT}`].sort());
    for (const p of solverPrompts) {
      assert.ok(!p.includes("x = 4") && !p.includes("2x = 8") && !p.includes("Proposed"));
    }
    const comparer = calls.find((c) => c.role === "comparer" && c.user.includes(STATEMENT))!;
    assert.match(comparer.user, /1\. 2x = 11 - 3/);
    assert.match(comparer.user, /Proposed final answer: x = 4/);
    assert.match(comparer.user, /independent solver's final answer: x = 4/);
  });

  it("the check runs on the advanced ask model whatever TEACH_LEVEL says", async () => {
    const seen: string[] = [];
    const { models } = routed(agree);
    const spy: ModelFactory = { ...models, language: (cfg, key) => { seen.push(cfg.model); return models.language(cfg, key); } };
    await run(practiceBody(), spy, env({ TEACH_LEVEL: "high_school" }));
    assert.deepEqual([...new Set(seen)].sort(), ["gpt-6-luna", "gpt-6.1-sol"]);
  });

  const notChecked = async (comparer: string, solver = SOLVED) => {
    const { models, calls } = routed({ practice: j(PRACTICE), solver, comparer });
    const r = await reply(await run(practiceBody(), models));
    return { r, calls };
  };

  it("disagree, not single and a wrong step each give problem null, reason not_checked, no reference, no regeneration, and one event", async () => {
    const cases: [string, string][] = [
      ["disagree", j({ equivalent: false, single_answer: true, first_wrong_step: null })],
      ["not_single", j({ equivalent: true, single_answer: false, first_wrong_step: null })],
      ["wrong_step", j({ equivalent: true, single_answer: true, first_wrong_step: 2 })],
    ];
    for (const [label, comparer] of cases) {
      logs.lines.length = 0;
      const { r, calls } = await notChecked(comparer);
      assert.deepEqual([r.status, r.json.problem, r.json.problem_ref, r.json.reason], [200, null, null, "not_checked"], label);
      assert.equal(calls.filter((c) => c.role === "practice").length, 1, "one generation, never regenerated");
      assert.equal(eventLogs("practice_not_checked").length, 1);
      assert.deepEqual([lastLog().checker, lastLog().reason], [label, "practice_not_checked"]);
    }
  });

  it("malformed solver or comparer output is not_checked, not an error and not a pass", async () => {
    const solverJunk = await notChecked(AGREE, "nonsense");
    assert.deepEqual([solverJunk.r.status, solverJunk.r.json.reason, lastLog().checker], [200, "not_checked", "malformed"]);
    const comparerJunk = await notChecked("nonsense");
    assert.deepEqual([comparerJunk.r.json.reason, lastLog().checker], ["not_checked", "malformed"]);
  });

  it("a practice problem equal to the example is not_checked (same_as_example)", async () => {
    const same = { ...PRACTICE, prompt_plain: LESSON.example.prompt_plain };
    const { models } = routed({ practice: j(same), solver: SOLVED, comparer: AGREE });
    const r = await reply(await run(practiceBody(), models));
    assert.deepEqual([r.json.reason, lastLog().checker], ["not_checked", "same_as_example"]);
  });

  it("a rejected example is withheld (example_checked false, one event) while the practice problem still goes out", async () => {
    let comparerCalls = 0;
    const comparer = () => {
      comparerCalls += 1;
      return comparerCalls === 1 ? j({ equivalent: false, single_answer: true, first_wrong_step: null }) : AGREE;
    };
    // The example's comparer call runs first in this fake (the example check starts before the practice one).
    const { models } = routed({ practice: j(PRACTICE), solver: SOLVED, comparer });
    const r = await reply(await run(practiceBody(), models));
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.example_checked, lastLog().example_check, lastLog().example_withheld], [false, "disagree", true]);
    assert.equal(eventLogs("example_withheld").length, 1);
  });

  it("no example sent: nothing to check or withhold, example_checked is false, the practice problem still goes out", async () => {
    const { models, calls } = routed(agree);
    const r = await reply(await run(practiceBody({ example: undefined }), models));
    assert.deepEqual([r.status, r.json.example_checked, r.json.reason, (r.json.problem as { prompt_plain: string }).prompt_plain], [200, false, null, STATEMENT]);
    assert.deepEqual(calls.map((c) => c.role).sort(), ["comparer", "practice", "solver"]);
    assert.equal(eventLogs("example_withheld").length, 0);
    assert.doesNotMatch(calls.find((c) => c.role === "practice")!.user, /do not reuse it/);
  });

  it("generation over a limit is 502 teach_too_long; the generator's output is never trimmed", async () => {
    const { models } = routed({ practice: j({ ...PRACTICE, steps: Array.from({ length: 9 }, (_, i) => `step ${i}`) }), solver: SOLVED, comparer: AGREE });
    const r = await reply(await run(practiceBody(), models));
    assert.deepEqual([r.status, r.json.error], [502, "teach_too_long"]);
    const longStatement = routed({ practice: j({ ...PRACTICE, prompt_plain: "q".repeat(301) }), solver: SOLVED, comparer: AGREE });
    assert.equal((await reply(await run(practiceBody(), longStatement.models))).json.error, "teach_too_long");
  });

  it("a provider failure during the check is a failed request, not a rejection and not a pass", async () => {
    const { models } = routed({ practice: j(PRACTICE), solver: () => { throw new Error("provider down"); }, comparer: AGREE });
    const r = await reply(await run(practiceBody(), models));
    assert.equal(r.status, 502);
    assert.equal(r.json.error, "model_error");
  });

  it("without TEACH_SEAL_KEY practice is 503 teach_unavailable (explain still works); an invalid key counts as no key", async () => {
    const { models, calls } = routed({ ...agree, explain: j(LESSON) });
    const r = await reply(await run(practiceBody(), models, liveEnv()));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "teach_unavailable", "TEACH_SEAL_KEY is not set"]);
    assert.equal(calls.length, 0);
    assert.equal((await reply(await run(practiceBody(), models, env({ TEACH_SEAL_KEY: "short" })))).status, 503);
    assert.equal((await reply(await run(teachBody(), models, liveEnv()))).status, 200);
  });

  it("a prefetch charges no seconds, and scripted mode hands back a sealed problem that the watch path accepts", async () => {
    const { models } = routed(agree);
    await run(practiceBody(), models);
    assert.deepEqual([lastLog().counted_kind, lastLog().charge_reason], ["question", "no_activity_reported"]);
    const scripted = await reply(await handleTeach(post("/api/teach", practiceBody()), deps({ TUTOR_SCRIPTED: "1" })));
    assert.equal(scripted.status, 200);
    const problem = scripted.json.problem as { id: string; prompt_plain: string };
    const watch = await reply(
      await handleWatch(post("/api/watch", watchBody({ problem_id: problem.id, problem_text: problem.prompt_plain, problem_ref: scripted.json.problem_ref })), deps({ TUTOR_SCRIPTED: "1" })),
    );
    assert.equal(watch.status, 200);
    assert.equal(lastLog().reference, "accepted");
  });
});

describe("POST /api/teach: solve (Show me how)", () => {
  const solveBody = (overrides: Record<string, unknown> = {}) => ({ action: "solve", session_id: "s1", course: COURSE, problem_id: `own:${COURSE}`, problem_text: STATEMENT, ...overrides });
  const OWN_SOLUTION = { steps: ["Subtract 3 from both sides: 2x = 8", "Divide both sides by 2: x = 4"], final_answer: "x = 4" };
  const agree = { solve: j(OWN_SOLUTION), solver: SOLVED, comparer: AGREE };
  const comparer = (equivalent: boolean, single_answer: boolean, first_wrong_step: number | null) => j({ equivalent, single_answer, first_wrong_step });
  const noModel = () => deps(env());

  it("a bank problem returns its stored worked solution and answer, every step, with no model call", async () => {
    const bank = findProblem("la-02")!;
    assert.ok(bank.worked_solution.length > 6, "la-02 has more steps than ExampleSchema allows");
    const r = await reply(await handleTeach(post("/api/teach", solveBody({ course: "linear-algebra", problem_id: "la-02", problem_text: undefined })), noModel()));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.solution, { steps: bank.worked_solution, final_answer: bank.final_answer });
    assert.deepEqual([r.json.reason, r.json.model], [null, "stored"]);
    assert.deepEqual([lastLog().kind, lastLog().problem_kind, lastLog().reason, lastLog().steps], ["bank", "bank", "solution_bank", bank.worked_solution.length]);
  });

  it("a practice problem returns the sealed reference's steps and answer with no model call; an expired or damaged reference is 422 practice_expired", async () => {
    const r = await reply(await handleTeach(post("/api/teach", solveBody({ problem_ref: sealed() })), noModel()));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.solution, { steps: STEPS, final_answer: ANSWER });
    assert.deepEqual([lastLog().kind, lastLog().reference], ["practice", "accepted"]);
    const old = sealed(STATEMENT, COURSE, new Date(FIXED_NOW.getTime() - SEAL_TTL_MS - 5000));
    for (const ref of [old, "junk"]) {
      const bad = await reply(await handleTeach(post("/api/teach", solveBody({ problem_ref: ref })), noModel()));
      assert.deepEqual([bad.status, bad.json.error, bad.json.solution], [422, "practice_expired", undefined]);
    }
  });

  it("an own problem: generated by the advanced model, checked by the blind solver and the comparer, then returned; the check never sees the generator's steps in call 1", async () => {
    const { models, calls } = routed(agree);
    const r = await reply(await run(solveBody(), models));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.solution, OWN_SOLUTION);
    assert.deepEqual([r.json.reason, r.json.model], [null, "gpt-6.1-sol"]);
    assert.deepEqual(calls.map((c) => c.role).sort(), ["comparer", "solve", "solver"]);
    assert.equal(calls.find((c) => c.role === "solver")!.user, `Problem: ${STATEMENT}`);
    assert.match(calls.find((c) => c.role === "comparer")!.user, /1\. Subtract 3 from both sides/);
    const entry = lastLog();
    assert.deepEqual([entry.kind, entry.checker, entry.reason, entry.checker_equivalent, entry.checker_single_answer, entry.checker_wrong_step], ["own", "agree", "solution_checked", true, true, false]);
    assert.ok(typeof entry.est_cost_usd === "number" && entry.est_cost_usd > 0);
    const text = logs.raw.join("\n");
    for (const secret of [STATEMENT, "Subtract 3", "x = 4"]) assert.ok(!text.includes(secret), secret);
  });

  it("disagreement is 200 solution null, not_checked, with one event and no regeneration", async () => {
    const { models, calls } = routed({ ...agree, comparer: comparer(false, true, null) });
    const r = await reply(await run(solveBody(), models));
    assert.deepEqual([r.status, r.json.solution, r.json.reason], [200, null, "not_checked"]);
    assert.equal(calls.filter((c) => c.role === "solve").length, 1);
    assert.equal(eventLogs("solve_not_checked").length, 1);
    assert.deepEqual([lastLog().checker, lastLog().reason], ["disagree", "solve_not_checked"]);
  });

  it("an answer set that is not single (several answers, or none) is accepted when no step is wrong", async () => {
    const { models } = routed({ solve: j({ steps: ["Subtract 3: 2x = 8", "x = 4 or x = -4"], final_answer: "x = 4 or x = -4" }), solver: j({ final_answer: "x = 4 or x = -4" }), comparer: comparer(true, false, null) });
    const r = await reply(await run(solveBody({ problem_text: "x^2 = 16" }), models));
    assert.equal(r.status, 200);
    assert.equal((r.json.solution as { final_answer: string }).final_answer, "x = 4 or x = -4");
    assert.deepEqual([lastLog().checker, lastLog().checker_single_answer, lastLog().reason], ["not_single", false, "solution_checked"]);
  });

  it("several answers combined with a wrong step is rejected: the flags are kept, not collapsed into not_single", async () => {
    const { models } = routed({ ...agree, comparer: comparer(true, false, 2) });
    const r = await reply(await run(solveBody(), models));
    assert.deepEqual([r.status, r.json.solution, r.json.reason], [200, null, "not_checked"]);
    assert.deepEqual([lastLog().checker, lastLog().checker_wrong_step], ["not_single", true]);
    const single = await reply(await run(solveBody(), routed({ ...agree, comparer: comparer(true, true, 1) }).models));
    assert.deepEqual([single.json.solution, single.json.reason], [null, "not_checked"]);
  });

  it("a closing full stop on the answer is dropped, an empty step list is not_checked, and a provider failure is a failed request, not a rejection", async () => {
    const dotted = await reply(await run(solveBody(), routed({ ...agree, solve: j({ ...OWN_SOLUTION, final_answer: "x = 4." }) }).models));
    assert.equal((dotted.json.solution as { final_answer: string }).final_answer, "x = 4");
    const empty = await reply(await run(solveBody(), routed({ ...agree, solve: j({ steps: [], final_answer: "x = 4" }) }).models));
    assert.deepEqual([empty.status, empty.json.solution, empty.json.reason], [200, null, "not_checked"]);
    assert.equal(lastLog().checker, "malformed");
    const { models } = routed({ ...agree, solver: () => { throw new Error("provider down"); } });
    const failed = await reply(await run(solveBody(), models));
    assert.deepEqual([failed.status, failed.json.solution], [502, undefined]);
  });

  it("an answer that asks several things may run to 200 characters, and 201 is teach_too_long", async () => {
    const long = "b".repeat(200);
    const ok = await reply(await run(solveBody(), routed({ ...agree, solve: j({ ...OWN_SOLUTION, final_answer: long }) }).models));
    assert.deepEqual([ok.status, (ok.json.solution as { final_answer: string }).final_answer.length], [200, 200]);
    const over = await reply(await run(solveBody(), routed({ ...agree, solve: j({ ...OWN_SOLUTION, final_answer: long + "x" }) }).models));
    assert.deepEqual([over.status, over.json.error], [502, "teach_too_long"]);
  });

  it("the solve prompt tells the writer to return nothing for a problem with no equation, so it is not_checked and never a request for input", async () => {
    const { models, calls } = routed({ ...agree, solve: j({ steps: [], final_answer: "" }) });
    const r = await reply(await run(solveBody({ problem_text: "Solve for x." }), models));
    assert.deepEqual([r.status, r.json.solution, r.json.reason], [200, null, "not_checked"]);
    assert.match(calls.find((c) => c.role === "solve")!.system, /missing what is needed to solve it/);
    assert.equal(calls.filter((c) => c.role !== "solve").length, 0, "nothing to check, so no check was paid for");
  });

  it("a step over 200 characters is teach_too_long (502), never trimmed", async () => {
    const { models } = routed({ ...agree, solve: j({ steps: ["x".repeat(201)], final_answer: "x = 4" }) });
    const r = await reply(await run(solveBody(), models));
    assert.deepEqual([r.status, r.json.error], [502, "teach_too_long"]);
    assert.equal(eventLogs("teach_too_long").length, 1);
  });

  it("scripted mode answers a typed problem from the script with no key, and a bank problem from the bank", async () => {
    const scripted = { APP_ACCESS_TOKEN: TOKEN, TUTOR_SCRIPTED: "1" };
    const own = await reply(await handleTeach(post("/api/teach", solveBody()), deps(scripted)));
    assert.deepEqual([own.status, own.json.solution, own.json.model], [200, SCRIPTED_SOLUTION, "scripted"]);
    const bank = await reply(await handleTeach(post("/api/teach", solveBody({ course: "linear-algebra", problem_id: "la-04", problem_text: undefined })), deps(scripted)));
    assert.equal((bank.json.solution as { final_answer: string }).final_answer, findProblem("la-04")!.final_answer);
  });

  it("rejects a missing problem id, an unknown problem and an own problem with no text with 422", async () => {
    for (const overrides of [{ problem_id: undefined }, { problem_id: "nope" }, { problem_text: undefined }, { problem_text: "x".repeat(501) }]) {
      const r = await reply(await handleTeach(post("/api/teach", solveBody(overrides)), noModel()));
      assert.equal(r.status, 422, JSON.stringify(overrides).slice(0, 40));
    }
  });
});

describe("GET /api/health", () => {
  it("reports teach_ready from the key's presence and never the key", async () => {
    const on = await (handleHealth(new Request("https://example.test/api/health"), env())).json() as Record<string, unknown>;
    assert.deepEqual([on.teach_ready, on.teach_level], [true, "advanced"]);
    const off = await (handleHealth(new Request("https://example.test/api/health"), liveEnv())).json() as Record<string, unknown>;
    assert.equal(off.teach_ready, false);
    assert.ok(!JSON.stringify(on).includes(KEY_HEX));
    const scripted = await (handleHealth(new Request("https://example.test/api/health"), { TUTOR_SCRIPTED: "1" })).json() as Record<string, unknown>;
    assert.equal(scripted.teach_ready, true);
  });
});
