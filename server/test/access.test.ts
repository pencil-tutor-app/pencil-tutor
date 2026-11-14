import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleAsk } from "../lib/ask.js";
import { handleHeartbeat } from "../lib/heartbeat.js";
import { handleMe } from "../lib/me.js";
import { handleWatch } from "../lib/watch.js";
import { askBody, captureLogs, deps, FIXED_NOW, post, reply, testStore, TEST_MONTH, TOKEN, UNKNOWN_CODE, watchBody } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SCRIPTED = { TUTOR_SCRIPTED: "1" };
const me = (code: string | null = TOKEN, method = "GET") => {
  const headers: Record<string, string> = {};
  if (code !== null) headers.authorization = `Bearer ${code}`;
  return new Request("https://example.test/api/me", { method, headers });
};
const allowanceOf = (json: Record<string, unknown>) => json.allowance as Record<string, unknown>;

// A clock the test moves forward.
function clock(start = FIXED_NOW) {
  let t = start.getTime();
  return { now: () => new Date(t), advance: (seconds: number) => void (t += seconds * 1000) };
}

describe("GET /api/me", () => {
  it("accepts a valid code and reports the plan and the full month ahead, without counting anything", async () => {
    const { store, id } = testStore();
    const r = await reply(await handleMe(me(), deps({}, undefined, { store })));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.plan, { live: false, cap_minutes: 480 });
    assert.deepEqual(
      [allowanceOf(r.json).month, allowanceOf(r.json).used_seconds, allowanceOf(r.json).remaining_minutes, allowanceOf(r.json).state, allowanceOf(r.json).notice],
      ["2026-11", 0, 480, "ok", null],
    );
    assert.equal(store.usageOf(id, TEST_MONTH).countedSeconds, 0, "checking a code is free");
  });

  it("reports live: true only for a student whose plan has it", async () => {
    const r = await reply(await handleMe(me(), deps({}, undefined, { store: testStore({ planLive: true }).store })));
    assert.deepEqual(r.json.plan, { live: true, cap_minutes: 480 });
  });

  it("refuses an unknown code, a malformed code and a missing code with 401, and a turned-off code with 403", async () => {
    const d = deps({});
    assert.equal((await handleMe(me(UNKNOWN_CODE), d)).status, 401);
    assert.equal((await handleMe(me("short"), d)).status, 401);
    assert.equal((await handleMe(me(null), d)).status, 401);
    const off = await reply(await handleMe(me(), deps({}, undefined, { store: testStore({ disabled: true }).store })));
    assert.deepEqual([off.status, off.json.error], [403, "code_disabled"]);
  });

  it("answers 405 to POST", async () => {
    assert.equal((await handleMe(me(TOKEN, "POST"), deps({}))).status, 405);
  });

  it("still answers (with the used-up allowance) when the hours are used up, so the app can show it", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 700 });
    const r = await reply(await handleMe(me(), deps({}, undefined, { store })));
    assert.equal(r.status, 200);
    assert.equal(allowanceOf(r.json).state, "used_up");
  });

  it("logs the student as a short hash, never the code, with the database time", async () => {
    await handleMe(me(), deps({}));
    const line = logs.lines[0]!;
    assert.match(String(line.student), /^[0-9a-f]{8}$/);
    assert.equal(line.db_queries, 1);
    assert.equal(typeof line.db_ms, "number");
    assert.ok(!logs.raw.join("\n").includes(TOKEN));
  });
});

describe("counting time from the requests the server already gets", () => {
  it("counts a look as activity: the first one charges 0 s, and the allowance comes back with it", async () => {
    const { store, id } = testStore();
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(SCRIPTED, undefined, { store })));
    assert.equal(r.status, 200);
    assert.equal(allowanceOf(r.json).used_seconds, 0, "nothing is charged ahead of time");
    assert.equal(allowanceOf(r.json).remaining_minutes, 480);
    assert.equal(store.usageOf(id, TEST_MONTH).looks, 1);
  });

  it("a second look 20 seconds later charges those 20 seconds", async () => {
    const { store } = testStore();
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    await handleWatch(post("/api/watch", watchBody()), d);
    c.advance(20);
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), d));
    assert.equal(allowanceOf(r.json).used_seconds, 20);
  });

  it("counts a question as activity too", async () => {
    const { store, id } = testStore();
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    await handleAsk(post("/api/ask", askBody()), d);
    c.advance(45);
    const r = await reply(await handleAsk(post("/api/ask", askBody()), d));
    assert.equal(r.status, 200);
    assert.equal(allowanceOf(r.json).used_seconds, 45);
    assert.equal(store.usageOf(id, TEST_MONTH).questions, 2);
  });

  it("does not count a request that fails validation", async () => {
    const { store, id } = testStore();
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ drawing_revision: undefined })), deps(SCRIPTED, undefined, { store })));
    assert.equal(r.status, 422);
    assert.equal(store.usageOf(id, TEST_MONTH).lastActivityAt, null, "not even a first moment was recorded");
  });

  it("counts steady activity as real time: a look every minute for ten minutes is ten minutes, nothing extra", async () => {
    const { store, id } = testStore();
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    for (let i = 0; i <= 10; i += 1) {
      await handleWatch(post("/api/watch", watchBody()), d);
      c.advance(60);
    }
    assert.equal(store.usageOf(id, TEST_MONTH).countedSeconds, 10 * 60);
  });

  it("does not count idle time: two looks 30 minutes apart count 0", async () => {
    const { store, id } = testStore();
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    await handleWatch(post("/api/watch", watchBody()), d);
    c.advance(30 * 60);
    await handleWatch(post("/api/watch", watchBody()), d);
    assert.equal(store.usageOf(id, TEST_MONTH).countedSeconds, 0);
  });

  it("starts a fresh month at zero on the 1st, Vancouver time", async () => {
    const { store, id } = testStore();
    // More than an hour either side of Vancouver midnight, so the time-zone database's winter offset does not matter.
    const nov = deps(SCRIPTED, undefined, { store, now: () => new Date("2026-12-01T06:30:00Z") });
    await handleWatch(post("/api/watch", watchBody()), nov);
    await handleWatch(post("/api/watch", watchBody()), deps(SCRIPTED, undefined, { store, now: () => new Date("2026-12-01T09:00:00Z") }));
    const dec = await reply(await handleWatch(post("/api/watch", watchBody()), deps(SCRIPTED, undefined, { store, now: () => new Date("2026-12-01T09:00:10Z") })));
    assert.equal(allowanceOf(dec.json).month, "2026-12");
    assert.equal(allowanceOf(dec.json).used_seconds, 10, "only December's 10 seconds; the November moment is not carried over");
    assert.equal(store.usageOf(id, "2026-11-01").countedSeconds, 0);
  });

  it("serves the request, logs an error, and does not lock the student out when counting fails after the checks passed", async () => {
    const { store } = testStore();
    store.chargeActivity = async () => {
      throw new Error("db down");
    };
    const res = await handleWatch(post("/api/watch", watchBody()), deps(SCRIPTED, undefined, { store }));
    assert.equal(res.status, 200);
    const failed = logs.lines.find((l) => l.outcome === "meter_failed");
    assert.ok(failed && failed.level === "error", "the failure is logged loudly");
  });
});

describe("heartbeat", () => {
  const beat = (body: unknown = { session_id: "s1", problem_id: "u3-04" }, code: string | null = TOKEN) => post("/api/heartbeat", body, code);
  const beatAfter = (secondsAgo: number) => beat({ session_id: "s1", problem_id: "u3-04", seconds_since_activity: secondsAgo });

  it("is not activity by itself: a heartbeat that reports nothing charges 0 s, however many arrive", async () => {
    const { store, id } = testStore();
    const c = clock();
    const d = deps({}, undefined, { store, now: c.now });
    for (let i = 0; i < 20; i += 1) {
      const r = await reply(await handleHeartbeat(beat(), d));
      assert.equal(r.status, 200);
      assert.equal(allowanceOf(r.json).used_seconds, 0);
      c.advance(30);
    }
    assert.equal(store.usageOf(id, TEST_MONTH).countedSeconds, 0, "an iPad left on the table accrues nothing");
    assert.equal(store.usageOf(id, TEST_MONTH).lastActivityAt, null);
    const line = logs.lines.at(-1)!;
    assert.deepEqual([line.counted_kind, line.charged_seconds, line.charge_reason, line.heartbeat_activity], ["heartbeat", 0, "no_activity_reported", "none_reported"]);
  });

  it("charges the real gap between the activity moments it reports, and a repeat of one already counted is free", async () => {
    const { store, id } = testStore();
    const c = clock();
    const d = deps({}, undefined, { store, now: c.now });
    // The app ticks every 30 s and reports how long ago the student's latest ink was.
    const first = await reply(await handleHeartbeat(beatAfter(2), d)); // ink at 2 s before the first tick
    assert.equal(allowanceOf(first.json).used_seconds, 0, "the first moment charges 0");
    c.advance(30);
    const second = await reply(await handleHeartbeat(beatAfter(2), d)); // ink 30 s after the first moment
    assert.equal(allowanceOf(second.json).used_seconds, 30);
    const line = logs.lines.at(-1)!;
    assert.deepEqual([line.charged_seconds, line.charge_reason, line.gap_seconds, line.seconds_since_activity], [30, "counted", 30, 2]);
    c.advance(30);
    const repeat = await reply(await handleHeartbeat(beatAfter(32), d)); // the same moment again, now 32 s old
    assert.equal(allowanceOf(repeat.json).used_seconds, 30, "the same moment reported twice is charged once");
    assert.equal(logs.lines.at(-1)!.charge_reason, "not_newer");
    assert.equal(store.usageOf(id, TEST_MONTH).looks, 0, "a heartbeat is not a look");
  });

  it("charges 0 and says why when the reported moment is more than 60 seconds after the last one", async () => {
    const { store } = testStore();
    const c = clock();
    const d = deps({}, undefined, { store, now: c.now });
    await handleHeartbeat(beatAfter(0), d);
    c.advance(5 * 60);
    const r = await reply(await handleHeartbeat(beatAfter(0), d));
    assert.equal(allowanceOf(r.json).used_seconds, 0);
    const line = logs.lines.at(-1)!;
    assert.deepEqual([line.charged_seconds, line.charge_reason, line.gap_seconds], [0, "gap_over_60s", 300]);
  });

  it("works together with looks: a look, then ink reported 30 seconds later, is 30 seconds of work", async () => {
    const { store } = testStore();
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    await handleWatch(post("/api/watch", watchBody()), d);
    c.advance(40);
    const r = await reply(await handleHeartbeat(beatAfter(10), d)); // ink at +30
    assert.equal(allowanceOf(r.json).used_seconds, 30);
  });

  it("ignores a nonsense age (negative, over an hour) with 0 s charged and the reason logged; a non-number is refused", async () => {
    const { store } = testStore();
    const d = deps({}, undefined, { store });
    for (const bad of [-5, 3601, 1e12]) {
      const r = await reply(await handleHeartbeat(beatAfter(bad), d));
      assert.equal(r.status, 200);
      assert.equal(allowanceOf(r.json).used_seconds, 0);
      assert.equal(logs.lines.at(-1)!.heartbeat_activity, "out_of_range");
    }
    assert.equal((await handleHeartbeat(beat({ problem_id: "u3-04", seconds_since_activity: "soon" }), d)).status, 422);
  });

  it("needs a code, a known problem and a JSON body", async () => {
    const d = deps({});
    assert.equal((await handleHeartbeat(beat(undefined, null), d)).status, 401);
    assert.equal((await handleHeartbeat(beat({ problem_id: "nope-99" }), d)).status, 422);
    assert.equal((await handleHeartbeat(beat({}), d)).status, 422);
    const bad = new Request("https://example.test/api/heartbeat", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` }, body: "{nope" });
    assert.equal((await handleHeartbeat(bad, d)).status, 400);
  });

  it("is refused with 403 hours_used_up when the hours are gone", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 600 });
    const r = await reply(await handleHeartbeat(beat(), deps({}, undefined, { store })));
    assert.deepEqual([r.status, r.json.error], [403, "hours_used_up"]);
  });
});

describe("the 80% and 100% notices and the stop", () => {
  it("sends the low notice on exactly one response, the used-up notice on exactly one, then refuses with 403 and counts nothing more", async () => {
    // A 10 minute cap, one look a minute. Counted time after look n (n = 1...) is 60 (n - 1) seconds.
    const { store, id } = testStore({ capSeconds: 600 });
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    const seen: { n: number; status: number; state: unknown; notice: unknown; used: unknown }[] = [];
    for (let n = 1; n <= 14; n += 1) {
      const r = await reply(await handleWatch(post("/api/watch", watchBody()), d));
      const a = allowanceOf(r.json);
      seen.push({ n, status: r.status, state: a.state, notice: a.notice, used: a.used_seconds });
      c.advance(60);
    }
    const notices = seen.filter((s) => s.notice !== null);
    assert.deepEqual(
      notices.map((s) => [s.n, s.notice]),
      [
        [9, "low"], // 60 * 8 = 480 s = 80% of 600
        [11, "used_up"], // 60 * 10 = 600 s = 100%
      ],
    );
    assert.deepEqual(seen.filter((s) => s.status === 403).map((s) => s.n), [12, 13, 14], "after the hours are used up, every request is refused");
    assert.equal(store.usageOf(id, TEST_MONTH).countedSeconds, 600, "a refused request counts nothing");
    assert.equal(seen[7]!.state, "ok");
    assert.equal(seen[8]!.state, "low");
    assert.equal(seen[10]!.state, "used_up");
  });

  it("a single jump from ok to used up sends only the used-up notice; the low notice never fires later", async () => {
    const { store, id } = testStore({ capSeconds: 100 });
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store, now: c.now });
    await handleWatch(post("/api/watch", watchBody()), d); // 0 s
    c.advance(60);
    const mid = await reply(await handleWatch(post("/api/watch", watchBody()), d)); // 60 s of 100
    assert.equal(allowanceOf(mid.json).state, "ok");
    store.setUsage(id, TEST_MONTH, { countedSeconds: 99 }); // 1 s short of the cap
    c.advance(30);
    const jump = await reply(await handleWatch(post("/api/watch", watchBody()), d)); // 99 + 30 = 129 of 100
    assert.equal(allowanceOf(jump.json).state, "used_up");
    assert.equal(allowanceOf(jump.json).notice, "used_up");
    const next = await reply(await handleWatch(post("/api/watch", watchBody()), d));
    assert.deepEqual([next.status, next.json.error], [403, "hours_used_up"]);
    assert.equal(allowanceOf(next.json).notice, null, "the refusal carries the state, not a second notice");
  });

  it("the 403 for used-up hours carries the allowance so the app can show the banner", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 600 });
    const r = await reply(await handleAsk(post("/api/ask", askBody()), deps(SCRIPTED, undefined, { store })));
    assert.equal(r.status, 403);
    assert.deepEqual([allowanceOf(r.json).state, allowanceOf(r.json).remaining_minutes], ["used_up", 0]);
  });

  it("a top-up for the month (bonus seconds) lets the student continue", async () => {
    const { store, id } = testStore({ capSeconds: 600 });
    store.setUsage(id, TEST_MONTH, { countedSeconds: 600, bonusSeconds: 1200 });
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(SCRIPTED, undefined, { store })));
    assert.equal(r.status, 200);
    assert.equal(allowanceOf(r.json).cap_seconds, 1800);
  });

  it("logs the state, the minutes left, the seconds charged and why, on every counted request", async () => {
    const c = clock();
    const d = deps(SCRIPTED, undefined, { store: testStore().store, now: c.now });
    await handleWatch(post("/api/watch", watchBody()), d);
    const first = logs.lines[0]!;
    assert.deepEqual(
      [first.counted_kind, first.allowance_state, first.used_seconds, first.cap_seconds, first.remaining_minutes, first.charged_seconds, first.charge_reason],
      ["look", "ok", 0, 28800, 480, 0, "first_activity"],
    );
    c.advance(25);
    await handleWatch(post("/api/watch", watchBody()), d);
    const second = logs.lines[1]!;
    assert.deepEqual([second.used_seconds, second.charged_seconds, second.charge_reason, second.gap_seconds], [25, 25, "counted", 25]);
  });
});
