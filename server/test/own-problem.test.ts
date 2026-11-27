import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleAsk } from "../lib/ask.js";
import { handleConsult } from "../lib/consult.js";
import { finalizeDecision, revealsAnswer } from "../lib/decision.js";
import { handleHeartbeat } from "../lib/heartbeat.js";
import { handleLiveSession, type LiveGateway, type LiveSessionConfig } from "../lib/live.js";
import { buildAskPrompt, buildConsultPrompt, buildLiveInstructions, buildWatchPrompt, LIVE_OWN_PROBLEM_NOTE, NO_REFERENCE_NOTE } from "../lib/policy.js";
import { checkProblemId, findProblem, levelOf, OWN_PROBLEM_LEVEL, OWN_TEXT_MAX_CHARS, resolveProblem } from "../lib/problems.js";
import { acceptReword } from "../lib/record/reword.js";
import { handleWatch } from "../lib/watch.js";
import { roleConfig } from "../lib/config.js";
import { askBody, captureLogs, deps, fakeModels, liveEnv, makePng, post, reply, testStore, watchBody } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const STATEMENT = "7x - 4 = 3x + 16";
const own = (overrides: Record<string, unknown> = {}) => ({ problem_id: "own:bc-math-9", problem_text: STATEMENT, ...overrides });
const lastLog = () => logs.lines.at(-1)!;

describe("resolveProblem", () => {
  it("resolves a bank id as before and ignores any problem_text sent with it", () => {
    const r = resolveProblem("u3-04", "something else");
    assert.ok(r.ok);
    assert.equal(r.problem, findProblem("u3-04"));
    assert.equal(r.problem.own, undefined);
  });

  it("resolves own:<course> to a problem with no worked solution and no final answer", () => {
    const r = resolveProblem("own:bc-math-9", STATEMENT);
    assert.ok(r.ok);
    assert.deepEqual(r.problem, {
      id: "own:bc-math-9",
      prompt_plain: STATEMENT,
      worked_solution: [],
      final_answer: "",
      course: "bc-math-9",
      level: OWN_PROBLEM_LEVEL,
      own: true,
    });
    assert.equal(levelOf(r.problem), OWN_PROBLEM_LEVEL);
  });

  it("trims the text and turns line breaks and runs of spaces into one space", () => {
    const r = resolveProblem("own:calculus-1", "  d/dx of  x^2\n\n  at x = 3  ");
    assert.ok(r.ok);
    assert.equal(r.problem.prompt_plain, "d/dx of x^2 at x = 3");
  });

  it("accepts exactly 500 characters and refuses 501, none, blank and a non-string", () => {
    assert.ok(resolveProblem("own:bc-math-9", "x".repeat(OWN_TEXT_MAX_CHARS)).ok);
    for (const text of ["x".repeat(OWN_TEXT_MAX_CHARS + 1), "", "  \n ", undefined]) {
      const r = resolveProblem("own:bc-math-9", text);
      assert.ok(!r.ok);
      assert.deepEqual([r.status, r.error], [422, "invalid_request"]);
    }
  });

  it("refuses a course that is not in the manifest, a bare own, and an unknown bank id", () => {
    const course = resolveProblem("own:not-a-course", STATEMENT);
    assert.ok(!course.ok);
    assert.deepEqual([course.status, course.error], [422, "unknown_course"]);
    assert.equal(resolveProblem("own", STATEMENT).ok, false);
    assert.equal(resolveProblem("own:", STATEMENT).ok, false);
    const bank = resolveProblem("nope-99");
    assert.ok(!bank.ok);
    assert.equal(bank.error, "unknown_problem");
  });

  it("checkProblemId (heartbeat) accepts a bank id and own:<course> without any text, and names the failure otherwise", () => {
    assert.equal(checkProblemId("u3-04"), undefined);
    assert.equal(checkProblemId("own:bc-math-9"), undefined);
    assert.equal(checkProblemId("own:nope")?.error, "unknown_course");
    assert.equal(checkProblemId("nope-99")?.error, "unknown_problem");
  });
});

describe("the no-reference prompt (watch, ask and consult)", () => {
  const problem = (() => {
    const r = resolveProblem("own:bc-math-9", STATEMENT);
    assert.ok(r.ok);
    return r.problem;
  })();

  it("says there is no reference solution and carries the typed statement, with no solution or answer lines", () => {
    const prompts = [
      buildWatchPrompt({ problem, lines: [], history: [] }),
      buildAskPrompt({ problem, transcript: "is this right?" }),
      buildConsultPrompt({ problem, question: "check my work", recent: [] }),
    ];
    for (const p of prompts) {
      assert.match(p, new RegExp(NO_REFERENCE_NOTE.slice(0, 60)));
      assert.match(p, /solve the problem yourself and recompute every number/);
      assert.match(p, /If a digit or sign is hard to read, wait/);
      assert.match(p, /The problem the student is solving: 7x - 4 = 3x \+ 16/);
      assert.doesNotMatch(p, /Reference worked solution/);
      assert.doesNotMatch(p, /Final answer:/);
    }
  });

  it("a bank problem keeps its reference block unchanged", () => {
    const p = buildWatchPrompt({ problem: findProblem("u3-04")!, lines: [], history: [] });
    assert.match(p, /Reference worked solution/);
    assert.match(p, /Final answer:/);
    assert.doesNotMatch(p, /no reference solution/);
  });

  it("the live voice gets one extra sentence for an own problem and none for a bank problem", () => {
    const withNote = buildLiveInstructions(problem);
    assert.ok(withNote.includes(LIVE_OWN_PROBLEM_NOTE));
    assert.ok(withNote.includes("The problem on the student's page is: 7x - 4 = 3x + 16"));
    assert.ok(!buildLiveInstructions(findProblem("u3-04")!).includes(LIVE_OWN_PROBLEM_NOTE));
  });
});

describe("empty final answer guards", () => {
  const ownProblem = (() => {
    const r = resolveProblem("own:bc-math-9", STATEMENT);
    assert.ok(r.ok);
    return r.problem;
  })();
  const interrupt = { action: "interrupt", line: 2, reason: "sign slip", hint_spoken: "Check the sign on that line.", hint_written: "Check the sign" };
  const lines = [1, 2].map((index) => ({ index, box: { x: 0, y: 0, w: 1, h: 1 } }));

  it("an interrupt on an own problem survives finalizeDecision (an empty answer is not found in every hint)", () => {
    const d = finalizeDecision(interrupt, lines, ownProblem);
    assert.deepEqual([d.action, d.line, d.label], ["interrupt", 2, "model_interrupt"]);
  });

  it("the same interrupt on a bank problem is still dropped when the hint holds the final answer", () => {
    const bank = findProblem("u3-04")!;
    const leaking = { ...interrupt, hint_spoken: `So ${bank.final_answer} it is.` };
    assert.equal(finalizeDecision(leaking, lines, bank).label, "hint_reveals_answer");
  });

  it("a reworded hint is accepted for an own problem and still refused on a leak for a bank problem", () => {
    assert.deepEqual(acceptReword("Look again at the minus sign.", ownProblem), { ok: true, text: "Look again at the minus sign." });
    const bank = findProblem("u3-04")!;
    assert.deepEqual(acceptReword(`So ${bank.final_answer} is what you want.`, bank), { ok: false, reason: "reveals_answer" });
  });

  it("revealsAnswer is false for an empty answer and true when the squashed answer is inside the text", () => {
    assert.equal(revealsAnswer("anything at all", ""), false);
    assert.equal(revealsAnswer("so x = 5", "x=5"), true);
    assert.equal(revealsAnswer("so x = 6", "x=5"), false);
  });
});

describe("watch, ask and consult with an own problem", () => {
  const goodInterrupt = JSON.stringify({ action: "interrupt", line: 2, reason: "sign slip", hint_spoken: "Check the sign on that line.", hint_written: "Check the sign" });

  it("watch: the model gets the no-reference prompt, the interrupt comes back, and the log has labels and counts only", async () => {
    const { models, prompts } = fakeModels(goodInterrupt);
    const r = await reply(await handleWatch(post("/api/watch", watchBody(own())), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    // The model is the one the own-problem level names (advanced: gpt-6.1-sol by default), not the high school default.
    assert.deepEqual([r.json.action, r.json.line, r.json.model], ["interrupt", 2, roleConfig("watch", liveEnv(), OWN_PROBLEM_LEVEL).model]);
    assert.equal(r.json.model, "gpt-6.1-sol");
    assert.equal(prompts.length, 1);
    assert.match(prompts[0]!, /There is no reference solution/);
    assert.match(prompts[0]!, /7x - 4 = 3x \+ 16/);
    const entry = lastLog();
    assert.deepEqual(
      [entry.problem_kind, entry.problem_text_chars, entry.course, entry.tier, entry.level],
      ["own", STATEMENT.length, "bc-math-9", OWN_PROBLEM_LEVEL === "advanced" ? "advanced" : "standard", OWN_PROBLEM_LEVEL],
    );
    assert.ok(!logs.raw.join("\n").includes(STATEMENT), "the student's text is never logged");
  });

  it("watch: a bank problem logs problem_kind bank and no text length", async () => {
    const { models } = fakeModels(JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null }));
    await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models));
    assert.deepEqual([lastLog().problem_kind, lastLog().problem_text_chars], ["bank", undefined]);
  });

  it("watch: 422 unknown_course, and 422 invalid_request for missing, blank or over-long text, before any model call", async () => {
    const { models, prompts } = fakeModels(goodInterrupt);
    const d = () => deps(liveEnv(), models);
    const course = await reply(await handleWatch(post("/api/watch", watchBody(own({ problem_id: "own:nope" }))), d()));
    assert.deepEqual([course.status, course.json.error], [422, "unknown_course"]);
    for (const problem_text of [undefined, "", "   ", "x".repeat(501), 42]) {
      const r = await reply(await handleWatch(post("/api/watch", watchBody(own({ problem_text }))), d()));
      assert.deepEqual([r.status, r.json.error], [422, "invalid_request"], JSON.stringify(problem_text)?.slice(0, 20));
    }
    assert.equal(prompts.length, 0);
  });

  it("scripted watch on an own problem waits (the script interrupts u3-04 only)", async () => {
    const r = await reply(await handleWatch(post("/api/watch", watchBody(own())), deps({ TUTOR_SCRIPTED: "1" })));
    assert.deepEqual([r.status, r.json.action], [200, "wait"]);
  });

  it("ask: the no-reference prompt reaches the model and the answer comes back", async () => {
    const { models, prompts } = fakeModels("Look at what you did to both sides.");
    const r = await reply(await handleAsk(post("/api/ask", askBody(own())), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.equal(r.json.answer_text, "Look at what you did to both sides.");
    assert.match(prompts[0]!, /There is no reference solution/);
    assert.deepEqual([lastLog().problem_kind, lastLog().problem_text_chars], ["own", STATEMENT.length]);
    const bad = await reply(await handleAsk(post("/api/ask", askBody(own({ problem_text: "" }))), deps(liveEnv(), models)));
    assert.deepEqual([bad.status, bad.json.error], [422, "invalid_request"]);
  });

  it("consult: the no-reference prompt reaches the model with the consult policy", async () => {
    const { models, prompts } = fakeModels("Line one is your equation. Nothing wrong so far.");
    const body = { session_id: "s1", ...own(), image_png_base64: makePng(800, 600), question: "check my work", recent: [] };
    const r = await reply(await handleConsult(post("/api/consult", body), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.match(prompts[0]!, /There is no reference solution/);
    assert.match(prompts[0]!, /page reader behind a voice math tutor/);
    assert.equal(lastLog().problem_kind, "own");
    const bad = await reply(await handleConsult(post("/api/consult", { ...body, problem_id: "own:nope" }), deps(liveEnv(), models)));
    assert.deepEqual([bad.status, bad.json.error], [422, "unknown_course"]);
  });
});

describe("live-session and heartbeat with an own problem", () => {
  const OFFER = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n";
  const withLive = (live: LiveGateway) => ({ ...deps(liveEnv(), undefined, { store: testStore({ planLive: true }).store }), live });
  function fakeLive() {
    const calls: LiveSessionConfig[] = [];
    const live: LiveGateway = {
      async createWebRtcSession(args) {
        calls.push(args.session);
        return { kind: "created", sessionId: "live_abc", answerSdp: "v=0\r\nANSWER" };
      },
    };
    return { live, calls };
  }

  it("live-session: the instructions carry the typed statement and the no-answer-key sentence", async () => {
    const { live, calls } = fakeLive();
    const r = await reply(await handleLiveSession(post("/api/live-session", { session_id: "s1", ...own(), sdp: OFFER }), withLive(live)));
    assert.equal(r.status, 200);
    assert.equal(calls.length, 1);
    assert.ok(calls[0]!.instructions.includes("The problem on the student's page is: 7x - 4 = 3x + 16"));
    assert.ok(calls[0]!.instructions.includes(LIVE_OWN_PROBLEM_NOTE));
    assert.deepEqual([lastLog().problem_kind, lastLog().problem_text_chars, lastLog().course], ["own", STATEMENT.length, "bc-math-9"]);
    assert.ok(!logs.raw.join("\n").includes(STATEMENT));
  });

  it("live-session: 422 without the text or with an unknown course, and OpenAI is never called", async () => {
    const { live, calls } = fakeLive();
    const noText = await reply(await handleLiveSession(post("/api/live-session", { session_id: "s1", problem_id: "own:bc-math-9", sdp: OFFER }), withLive(live)));
    assert.deepEqual([noText.status, noText.json.error], [422, "invalid_request"]);
    const course = await reply(await handleLiveSession(post("/api/live-session", { session_id: "s1", ...own({ problem_id: "own:nope" }), sdp: OFFER }), withLive(live)));
    assert.deepEqual([course.status, course.json.error], [422, "unknown_course"]);
    assert.equal(calls.length, 0);
  });

  it("heartbeat: accepts own:<course> with no text and meters the reported activity; an unknown course is 422 unknown_course", async () => {
    const d = deps({});
    const ok = await reply(await handleHeartbeat(post("/api/heartbeat", { session_id: "s1", problem_id: "own:bc-math-9", seconds_since_activity: 2 }), d));
    assert.equal(ok.status, 200);
    assert.equal(lastLog().heartbeat_activity, "reported");
    const bad = await reply(await handleHeartbeat(post("/api/heartbeat", { session_id: "s1", problem_id: "own:nope" }), d));
    assert.deepEqual([bad.status, bad.json.error], [422, "unknown_course"]);
  });
});
