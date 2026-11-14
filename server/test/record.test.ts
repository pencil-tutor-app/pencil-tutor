import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import { MockLanguageModelV4 } from "ai/test";
import { handleAsk } from "../lib/ask.js";
import { handleConsult } from "../lib/consult.js";
import { DatabaseError } from "../lib/db.js";
import type { Deps } from "../lib/gate.js";
import type { ModelFactory } from "../lib/models.js";
import { NOTICE, NOTICE_VERSION, noticeHash } from "../lib/record/notice.js";
import { handleMemoryAction, handleMemoryStatus, handlePrivacy, renderPolicyHtml } from "../lib/record/endpoint.js";
import { PRIVACY_POLICY_MD } from "../lib/record/policy-text.js";
import { acceptReword, buildRewordPrompt, recallPhrase } from "../lib/record/reword.js";
import type { Deleted, GivenBy, LookArgs, LookResult, Note, RecordStore, Status } from "../lib/record/store.js";
import { findProblem } from "../lib/problems.js";
import { handleWatch } from "../lib/watch.js";
import { askBody, captureLogs, deps, liveEnv, post, reply, TOKEN, testStore, watchBody } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

// ---------------------------------------------------------------- doubles

const NOTE_TEXT = "starts to doubt herself when told she is wrong; open with what is right";
const note: Note = { id: "1", sessionOn: "2026-11-09", body: NOTE_TEXT, pinned: false };
const emptyDeleted: Deleted = { withdrawn: 0, hints: 0, attempts: 0, notes: 0 };

class StubRecord implements RecordStore {
  readonly kind = "stub" as const;
  consented = true;
  notes: Note[] = [note];
  fail: Error | null = null;
  looks: { version: string; args: LookArgs }[] = [];
  questions: { sessionId: string; problemId: string }[] = [];
  grants: { givenBy: GivenBy; via: string; noticeVersion: string; noticeHash: string }[] = [];
  withdraws: { erase: boolean }[] = [];
  erases = 0;
  statusValue: Status = { consent: null, notes: 0, recent: [] };

  async recordLook(_id: string, version: string, args: LookArgs): Promise<LookResult> {
    if (this.fail) throw this.fail;
    this.looks.push({ version, args });
    return { consented: this.consented, notes: this.consented && args.wantNotes ? this.notes : [] };
  }
  async recordQuestion(_id: string, _version: string, args: { sessionId: string; problemId: string }): Promise<boolean> {
    if (this.fail) throw this.fail;
    this.questions.push(args);
    return this.consented;
  }
  async status(): Promise<Status> {
    if (this.fail) throw this.fail;
    return this.statusValue;
  }
  async grant(_id: string, args: { givenBy: GivenBy; via: string; noticeVersion: string; noticeHash: string }): Promise<void> {
    this.grants.push(args);
  }
  async withdraw(_id: string, _via: string, _v: string, erase: boolean): Promise<Deleted> {
    this.withdraws.push({ erase });
    return { ...emptyDeleted, withdrawn: 1, attempts: erase ? 2 : 0 };
  }
  async erase(): Promise<Deleted> {
    this.erases += 1;
    return { ...emptyDeleted, attempts: 2, hints: 1 };
  }
}

// A language model that answers from a list, one entry per call (an Error entry throws), and keeps what each call was sent.
function sequenced(texts: (string | Error)[]) {
  const calls: string[] = [];
  let i = 0;
  const language = new MockLanguageModelV4({
    doGenerate: async (options) => {
      calls.push(JSON.stringify(options.prompt));
      const next = texts[Math.min(i, texts.length - 1)];
      i += 1;
      if (next instanceof Error) throw next;
      return {
        content: [{ type: "text", text: next as string }],
        finishReason: { unified: "stop", raw: "stop" },
        usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } },
        warnings: [],
      };
    },
  });
  const models: ModelFactory = {
    language: () => language,
    transcription: () => {
      throw new Error("no transcription expected");
    },
    speech: () => {
      throw new Error("no speech expected");
    },
  };
  return { models, calls };
}

const DETECT = JSON.stringify({
  action: "interrupt",
  line: 2,
  reason: "sign slip",
  hint_spoken: "Check the sign when the minus multiplies the bracket.",
  hint_written: "Check the signs here",
});
const WAIT = JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null });
const REWORD_OK = JSON.stringify({ hint_spoken: "You are close. Look at what the minus does to the bracket." });

const ON = liveEnv({ STUDENT_RECORD: "on", STUDENT_RECORD_REWORD: "on" });
const withRecord = (env: Record<string, string | undefined>, models: ModelFactory, record: RecordStore): Deps => ({ ...deps(env, models, { store: testStore().store }), record });
const watch = async (d: Deps, overrides: Record<string, unknown> = {}) => reply(await handleWatch(post("/api/watch", watchBody(overrides)), d));

// ---------------------------------------------------------------- the consent text

describe("consent notice", () => {
  it("is pinned: changing the words without a new NOTICE_VERSION fails here", () => {
    // If this fails you changed the text people agree to. Bump NOTICE_VERSION (everyone is then asked again), update the hash,
    // and update docs/privacy-policy.md if the meaning changed.
    assert.equal(NOTICE_VERSION, "2026-11-14.1");
    assert.equal(noticeHash(), "10178607f9245635ad3743ffa59ee631935f528c0c2e4ed7c82abefd4be47f97");
  });

  it("is short enough to read in about a minute", () => {
    const words = [NOTICE.intro, ...NOTICE.sections.map((s) => `${s.heading} ${s.body}`)].join(" ").split(/\s+/).length;
    assert.ok(words < 330, `notice is ${words} words`);
  });
});

// ---------------------------------------------------------------- the spoken-hint rewriter's checks

describe("recall phrasing guard", () => {
  const mustFire = [
    "Like last time, check the sign.",
    "We did this one yesterday.",
    "Remember when you dropped the minus?",
    "You always forget the bracket.",
    "You tend to mix up the signs.",
    "As before, look at line two.",
    "Last week you got this one.",
  ];
  const mustNot = [
    "Check the sign again.",
    "Take another look at line two.",
    "You always need to change the sign when you move a term.",
    "Check what the minus does to the bracket.",
    "Try the last line again.",
    "Every time you move a term, flip its sign.",
  ];
  for (const text of mustFire) it(`fires on: ${text}`, () => assert.equal(recallPhrase(text), true));
  for (const text of mustNot) it(`stays quiet on: ${text}`, () => assert.equal(recallPhrase(text), false));
});

describe("acceptReword", () => {
  const problem = findProblem("u3-04")!;
  it("accepts a plain reworded hint", () => assert.deepEqual(acceptReword("Look at the minus and the bracket.", problem), { ok: true, text: "Look at the minus and the bracket." }));
  it("refuses empty, over-long, answer-revealing and history-claiming text", () => {
    assert.equal(acceptReword("  ", problem).ok, false);
    assert.equal(acceptReword("x".repeat(401), problem).ok, false);
    assert.deepEqual(acceptReword("So p = -4 is what you want.", problem), { ok: false, reason: "reveals_answer" });
    assert.deepEqual(acceptReword("Like last time, mind the sign.", problem), { ok: false, reason: "unsupported_history_claim" });
  });
  it("the rewriter's prompt carries the notes with their date and never the solution", () => {
    const text = buildRewordPrompt({ problem, line: 2, spoken: "Check the sign.", notes: [note] });
    assert.ok(text.includes("[n1] Edward, 2026-11-09:") && text.includes(NOTE_TEXT));
    assert.ok(!text.includes(problem.final_answer) && !text.includes(problem.worked_solution[0]!));
  });
});

// ---------------------------------------------------------------- /api/watch with the record

describe("watch with the opt-in record", () => {
  it("detection is unchanged across consecutive looks, and notes appear only in the second call", async () => {
    const withMemory = sequenced([DETECT, REWORD_OK, WAIT, WAIT]);
    const without = sequenced([DETECT, WAIT, WAIT]);
    const stubA = new StubRecord();
    const stubB = new StubRecord();
    stubB.consented = false;
    const a = withRecord(ON, withMemory.models, stubA);
    const b = withRecord(ON, without.models, stubB);

    // Three looks, the way the app makes them: the next look carries the WRITTEN hint of the interrupt in its history.
    const a1 = await watch(a);
    const b1 = await watch(b);
    const history = [{ at: "2026-11-13T01:00:10Z", action: "interrupt", line: 2, hint_written: b1.json.hint_written }];
    const a2 = await watch(a, { history, drawing_revision: 8 });
    const b2 = await watch(b, { history, drawing_revision: 8 });
    const a3 = await watch(a, { history, drawing_revision: 9 });
    const b3 = await watch(b, { history, drawing_revision: 9 });

    // The same detection requests reach the model for both students.
    assert.equal(withMemory.calls[0], without.calls[0]);
    assert.equal(withMemory.calls[2], without.calls[1]);
    assert.equal(withMemory.calls[3], without.calls[2]);
    // The decision and the written hint are the same; only the spoken hint differs, and only for the student with notes.
    assert.deepEqual([a1.json.action, a1.json.line, a1.json.hint_written], [b1.json.action, b1.json.line, b1.json.hint_written]);
    assert.notEqual(a1.json.hint_spoken, b1.json.hint_spoken);
    assert.equal(a1.json.hint_spoken, "You are close. Look at what the minus does to the bracket.");
    assert.deepEqual([a2.json.action, a3.json.action], [b2.json.action, b3.json.action]);
    // Edward's note reaches a model only in the one rewrite call.
    const carrying = withMemory.calls.filter((c) => c.includes("doubt herself"));
    assert.equal(carrying.length, 1);
    assert.equal(carrying[0], withMemory.calls[1]);
    assert.ok(!without.calls.some((c) => c.includes("doubt herself")));
    // The rewrite call sends no picture.
    assert.ok(!withMemory.calls[1]!.includes("image/") && !withMemory.calls[1]!.includes('"type":"file"'));
  });

  it("switch off: the record is never touched and the answer is the detection's", async () => {
    const m = sequenced([DETECT]);
    const stub = new StubRecord();
    const r = await watch(withRecord(liveEnv(), m.models, stub));
    assert.equal(r.status, 200);
    assert.equal(r.json.hint_spoken, "Check the sign when the minus multiplies the bracket.");
    assert.equal(stub.looks.length, 0);
    assert.equal(m.calls.length, 1);
  });

  it("recording on but reword switch off: records the look, no second call", async () => {
    const m = sequenced([DETECT]);
    const stub = new StubRecord();
    const r = await watch(withRecord(liveEnv({ STUDENT_RECORD: "on" }), m.models, stub));
    assert.equal(r.json.hint_spoken, "Check the sign when the minus multiplies the bracket.");
    assert.equal(m.calls.length, 1);
    assert.deepEqual(stub.looks[0]?.args, { sessionId: "s1", problemId: "u3-04", interrupt: { line: 2, revision: 7 }, wantNotes: false });
    assert.equal(stub.looks[0]?.version, NOTICE_VERSION);
  });

  it("no consent: one statement, nothing recorded, no notes, no second call", async () => {
    const m = sequenced([DETECT]);
    const stub = new StubRecord();
    stub.consented = false;
    const r = await watch(withRecord(ON, m.models, stub));
    assert.equal(r.json.hint_spoken, "Check the sign when the minus multiplies the bracket.");
    assert.equal(m.calls.length, 1);
    assert.equal(logs.lines.at(-1)?.memory_write, "skipped:no_consent");
  });

  it("a wait records the look and never asks for notes", async () => {
    const stub = new StubRecord();
    await watch(withRecord(ON, sequenced([WAIT]).models, stub));
    assert.deepEqual(stub.looks[0]?.args, { sessionId: "s1", problemId: "u3-04", interrupt: null, wantNotes: false });
  });

  for (const [name, text, label] of [
    ["a reworded hint that states the answer", JSON.stringify({ hint_spoken: "So p = -4." }), "fallback:reveals_answer"],
    ["a reworded hint that recalls an earlier lesson", JSON.stringify({ hint_spoken: "Like last time, mind the sign." }), "fallback:unsupported_history_claim"],
    ["output that is not the schema", "not json", "fallback:malformed"],
    ["a provider error", new Error("boom"), "fallback:provider_error_Error"],
  ] as const) {
    it(`keeps the original spoken hint after ${name}`, async () => {
      const m = sequenced([DETECT, text]);
      const r = await watch(withRecord(ON, m.models, new StubRecord()));
      assert.equal(r.status, 200);
      assert.equal(r.json.hint_spoken, "Check the sign when the minus multiplies the bracket.");
      assert.equal(r.json.hint_written, "Check the signs here");
      assert.equal(logs.lines.at(-1)?.reword, label.startsWith("fallback:malformed") ? "fallback:malformed" : label);
    });
  }

  it("a record that fails never fails the look", async () => {
    const stub = new StubRecord();
    stub.fail = new DatabaseError("db_timeout");
    const r = await watch(withRecord(ON, sequenced([DETECT]).models, stub));
    assert.equal(r.status, 200);
    assert.equal(r.json.hint_spoken, "Check the sign when the minus multiplies the bracket.");
    assert.equal(logs.lines.at(-1)?.memory_write, "failed:db_timeout");
  });

  it("the rewrite never changes the decision or the written hint, even if it tries", async () => {
    const m = sequenced([DETECT, JSON.stringify({ hint_spoken: "Fine, nothing wrong here.", action: "wait", line: 3, hint_written: "x" })]);
    const r = await watch(withRecord(ON, m.models, new StubRecord()));
    assert.deepEqual([r.json.action, r.json.line, r.json.hint_written], ["interrupt", 2, "Check the signs here"]);
  });

  it("logs counts and labels only: no note, no hint, no code", async () => {
    await watch(withRecord(ON, sequenced([DETECT, REWORD_OK]).models, new StubRecord()));
    const raw = logs.raw.join("\n");
    assert.ok(!raw.includes("doubt herself") && !raw.includes("minus does to the bracket") && !raw.includes("multiplies the bracket") && !raw.includes(TOKEN));
    const line = logs.lines.at(-1)!;
    assert.deepEqual([line.memory_write, line.memory_notes, line.reword], ["ok", 1, "used"]);
  });
});

describe("questions", () => {
  it("ask and consult count one question for a student who agreed, and nothing without the switch", async () => {
    const stub = new StubRecord();
    const env = { ...ON, TUTOR_SCRIPTED: "1" };
    await handleAsk(post("/api/ask", askBody()), withRecord(env, sequenced([WAIT]).models, stub));
    await handleConsult(
      post("/api/consult", { session_id: "s1", problem_id: "u3-04", image_png_base64: askBody().image_png_base64, question: "is this right?", recent: [] }),
      withRecord(env, sequenced([WAIT]).models, stub),
    );
    assert.equal(stub.questions.length, 2);
    const off = new StubRecord();
    await handleAsk(post("/api/ask", askBody()), withRecord({ ...liveEnv(), TUTOR_SCRIPTED: "1" }, sequenced([WAIT]).models, off));
    assert.equal(off.questions.length, 0);
  });
});

// ---------------------------------------------------------------- /api/memory

const get = (d: Deps) => handleMemoryStatus(new Request("https://example.test/api/memory", { headers: { authorization: `Bearer ${TOKEN}` } }), d);
const act = (d: Deps, body: unknown) => handleMemoryAction(post("/api/memory", body), d);
const consentBody = { action: "consent", given_by: "parent_guardian", notice_version: NOTICE_VERSION, attested: true };

describe("/api/memory", () => {
  it("says the feature is off when the switch is off and there is no record", async () => {
    const r = await reply(await get(withRecord(liveEnv(), sequenced([WAIT]).models, new StubRecord())));
    assert.deepEqual(r.json.feature, "off");
    assert.equal(r.json.notice, undefined);
  });

  it("offers the notice and the policy link when on", async () => {
    const r = await reply(await get(withRecord(ON, sequenced([WAIT]).models, new StubRecord())));
    assert.equal(r.json.feature, "on");
    const notice = r.json.notice as { version: string; sections: unknown[]; policy_url: string };
    assert.equal(notice.version, NOTICE_VERSION);
    assert.equal(notice.policy_url, "https://example.test/api/privacy");
    assert.equal(r.json.consent, null);
  });

  it("still lets someone with a record see and manage it after the switch goes off", async () => {
    const stub = new StubRecord();
    stub.statusValue = {
      consent: { granted: true, givenBy: "parent_guardian", recordedVia: "app", noticeVersion: NOTICE_VERSION, at: "2026-11-14T18:00:00.000Z" },
      notes: 2,
      recent: [{ problemId: "u3-04", looks: 5, asks: 1, interrupts: 2, lastAt: "2026-11-14T18:00:00.000Z" }],
    };
    const d = withRecord(liveEnv(), sequenced([WAIT]).models, stub);
    const r = await reply(await get(d));
    assert.equal(r.json.feature, "off");
    assert.deepEqual((r.json.consent as { current: boolean }).current, true);
    assert.deepEqual(r.json.record, { notes: 2, recent: [{ problem_id: "u3-04", looks: 5, asks: 1, interrupts: 2, last_at: "2026-11-14T18:00:00.000Z" }] });
    assert.equal((await reply(await act(d, { action: "withdraw", erase: true }))).status, 200);
    assert.equal((await reply(await act(d, { action: "erase" }))).status, 200);
    assert.deepEqual([stub.withdraws.length, stub.erases], [1, 1]);
  });

  it("an outdated agreement is not current", async () => {
    const stub = new StubRecord();
    stub.statusValue = { consent: { granted: true, givenBy: "adult_student", recordedVia: "admin", noticeVersion: "2026-01-01.1", at: "2026-11-14T18:00:00.000Z" }, notes: 0, recent: [] };
    const r = await reply(await get(withRecord(ON, sequenced([WAIT]).models, stub)));
    assert.equal((r.json.consent as { current: boolean }).current, false);
  });

  it("records an agreement with who, the text version and its hash; and logs it without the code", async () => {
    const stub = new StubRecord();
    const r = await reply(await act(withRecord(ON, sequenced([WAIT]).models, stub), consentBody));
    assert.equal(r.status, 200);
    assert.deepEqual(stub.grants, [{ givenBy: "parent_guardian", via: "app", noticeVersion: NOTICE_VERSION, noticeHash: noticeHash() }]);
    assert.ok(logs.lines.some((l) => l.event === "memory_consent_granted" && l.given_by === "parent_guardian"));
    assert.ok(!logs.raw.join("\n").includes(TOKEN));
  });

  it("refuses an agreement without the attestation, on an old text, with the switch off, or with a bad body", async () => {
    const stub = new StubRecord();
    const d = withRecord(ON, sequenced([WAIT]).models, stub);
    const noAttest = await reply(await act(d, { ...consentBody, attested: false }));
    assert.deepEqual([noAttest.status, noAttest.json.error], [422, "attestation_required"]);
    const stale = await reply(await act(d, { ...consentBody, notice_version: "2026-01-01.1" }));
    assert.deepEqual([stale.status, stale.json.error], [409, "notice_outdated"]);
    const off = await reply(await act(withRecord(liveEnv(), sequenced([WAIT]).models, stub), consentBody));
    assert.deepEqual([off.status, off.json.error], [404, "memory_not_available"]);
    assert.equal((await reply(await act(d, { action: "consent", given_by: "child" }))).status, 422);
    assert.equal(stub.grants.length, 0);
  });

  it("withdraw can keep or erase, and says what it deleted", async () => {
    const stub = new StubRecord();
    const d = withRecord(ON, sequenced([WAIT]).models, stub);
    const keep = await reply(await act(d, { action: "withdraw", erase: false }));
    assert.deepEqual(keep.json.deleted, { hints: 0, attempts: 0, notes: 0 });
    const erased = await reply(await act(d, { action: "withdraw", erase: true }));
    assert.equal((erased.json.deleted as { attempts: number }).attempts, 2);
    assert.deepEqual(stub.withdraws, [{ erase: false }, { erase: true }]);
  });

  it("works when the month's hours are used up (it costs nothing and is never counted)", async () => {
    const { store, id } = testStore({ capSeconds: 10 });
    store.setUsage(id, "2026-11-01", { countedSeconds: 100 });
    const d: Deps = { ...deps(ON, sequenced([WAIT]).models, { store }), record: new StubRecord() };
    assert.equal((await get(d)).status, 200);
    assert.equal((await act(d, { action: "erase" })).status, 200);
  });

  it("needs a code", async () => {
    const res = await handleMemoryStatus(new Request("https://example.test/api/memory"), withRecord(ON, sequenced([WAIT]).models, new StubRecord()));
    assert.equal(res.status, 401);
  });
});

// ---------------------------------------------------------------- the policy page

describe("policy page", () => {
  it("the copy the server serves equals docs/privacy-policy.md (run npm run sync-policy after editing it)", () => {
    const docs = readFileSync(new URL("../../docs/privacy-policy.md", import.meta.url), "utf8");
    assert.equal(PRIVACY_POLICY_MD, docs);
  });

  it("is served without a code as HTML and says it is a draft", async () => {
    const res = handlePrivacy(new Request("https://example.test/api/privacy"));
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /text\/html/);
    const html = await res.text();
    assert.ok(html.includes("<h1>Pencil Tutor privacy policy</h1>") && html.includes("DRAFT"));
    assert.equal(handlePrivacy(new Request("https://example.test/api/privacy", { method: "POST" })).status, 405);
  });

  it("escapes markup and only links http(s) addresses", () => {
    const html = renderPolicyHtml("# T\n\n<script>x</script> [ok](https://a.example) [bad](javascript:alert(1))\n\n- one\n- **two**");
    assert.ok(!html.includes("<script>") && html.includes("&lt;script&gt;"));
    assert.ok(html.includes('<a href="https://a.example">ok</a>') && !html.includes('href="javascript'));
    assert.ok(html.includes("<ul>") && html.includes("<strong>two</strong>"));
  });
});
