import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { splitStatements } from "../lib/students-admin.js";
import {
  allowanceOf,
  chargeFor,
  CODE_ALPHABET,
  codeHash,
  EMPTY_USAGE,
  generateCode,
  isValidCode,
  normalizeCode,
  vancouverMonth,
} from "../lib/students.js";

const at = (iso: string) => new Date(iso);

describe("student codes", () => {
  it("uses 30 unambiguous symbols: no I, L, O, U, 0 or 1", () => {
    assert.equal(CODE_ALPHABET.length, 30);
    assert.equal(new Set(CODE_ALPHABET).size, 30);
    for (const bad of "ILOU01") assert.ok(!CODE_ALPHABET.includes(bad), `alphabet has ${bad}`);
  });

  it("generates 8 characters from the alphabet, different each time", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 500; i += 1) {
      const code = generateCode();
      assert.equal(code.length, 8);
      assert.ok(isValidCode(code), code);
      seen.add(code);
    }
    assert.equal(seen.size, 500, "no repeats in 500 draws (30^8 is about 6.6e11)");
  });

  it("generateCode maps each random pick to one alphabet symbol", () => {
    let n = 0;
    assert.equal(generateCode(() => n++ % 30), CODE_ALPHABET.slice(0, 8));
  });

  it("accepts only exactly 8 characters from the alphabet, upper case", () => {
    assert.ok(isValidCode("K7MQ2XAB"));
    for (const bad of ["", "k7mq2xab", "K7MQ2XA", "K7MQ2XABC", "K7MQ2XA0", "K7MQ2XAI", "K7MQ-2XA", "K7MQ 2XA", "an-old-shared-token-value"]) {
      assert.ok(!isValidCode(bad), `"${bad}" must be refused`);
    }
  });

  it("normalizes what a person types: trim, upper case, drop spaces and dashes", () => {
    assert.equal(normalizeCode("  k7mq-2xab \n"), "K7MQ2XAB");
    assert.equal(normalizeCode("k7mq 2xab"), "K7MQ2XAB");
    assert.ok(isValidCode(normalizeCode("k7mq-2xab")));
  });

  it("logs only a short salted hash, never the code", () => {
    const hash = codeHash("K7MQ2XAB");
    assert.match(hash, /^[0-9a-f]{8}$/);
    assert.notEqual(hash, codeHash("K7MQ2XAC"));
    assert.ok(!hash.includes("K7MQ"));
  });
});

describe("counting time: the gaps between real activity moments", () => {
  // Feeds moments (seconds from a start) through chargeFor and returns the total counted.
  function replay(momentsInSeconds: number[]) {
    const start = at("2026-11-14T18:00:00Z").getTime();
    let last: Date | null = null;
    let total = 0;
    const reasons: string[] = [];
    for (const s of momentsInSeconds) {
      const r = chargeFor(last, new Date(start + s * 1000));
      total += r.seconds;
      last = r.lastActivityAt;
      reasons.push(r.reason);
    }
    return { total, reasons };
  }

  it("charges nothing for the first moment: no time is charged ahead", () => {
    const r = chargeFor(null, at("2026-11-14T18:00:00Z"));
    assert.deepEqual([r.seconds, r.reason], [0, "first_activity"]);
    assert.equal(r.lastActivityAt?.toISOString(), "2026-11-14T18:00:00.000Z");
  });

  it("charges the whole gap when the next moment comes within 60 seconds", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00Z"));
    const second = chargeFor(first.lastActivityAt, at("2026-11-14T18:00:45Z"));
    assert.deepEqual([second.seconds, second.reason, second.gapSeconds], [45, "counted", 45]);
    assert.equal(chargeFor(first.lastActivityAt, at("2026-11-14T18:01:00Z")).seconds, 60, "exactly 60 s still counts");
  });

  it("charges nothing for a gap longer than 60 seconds (the student was away or idle), and starts over from there", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00Z"));
    const later = chargeFor(first.lastActivityAt, at("2026-11-14T18:01:01Z"));
    assert.deepEqual([later.seconds, later.reason, later.gapSeconds], [0, "gap_over_60s", 61]);
    const next = chargeFor(later.lastActivityAt, at("2026-11-14T18:01:11Z"));
    assert.equal(next.seconds, 10, "the next gap is measured from the late moment");
  });

  it("charges nothing for a second moment in the same second, or for one older than what was counted", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00.200Z"));
    const again = chargeFor(first.lastActivityAt, at("2026-11-14T18:00:00.900Z"));
    assert.deepEqual([again.seconds, again.reason], [0, "not_newer"]);
    const ahead = chargeFor(first.lastActivityAt, at("2026-11-14T18:00:30Z"));
    const stale = chargeFor(ahead.lastActivityAt, at("2026-11-14T18:00:10Z"));
    assert.deepEqual([stale.seconds, stale.reason], [0, "not_newer"]);
    assert.equal(stale.lastActivityAt?.getTime(), ahead.lastActivityAt?.getTime(), "the last-activity time never moves back");
  });

  it("charges nothing when the request reported no activity, and keeps the last-activity time", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00Z"));
    const none = chargeFor(first.lastActivityAt, null);
    assert.deepEqual([none.seconds, none.reason], [0, "no_activity_reported"]);
    assert.equal(none.lastActivityAt?.getTime(), first.lastActivityAt?.getTime());
  });

  it("an hour of steady activity every 30 seconds counts as exactly an hour, with nothing added at either end", () => {
    const moments = Array.from({ length: 121 }, (_, i) => i * 30);
    assert.equal(replay(moments).total, 3600);
  });

  it("a student who opens a problem and leaves the iPad on the table accrues nothing", () => {
    // One moment (they touched it), then silence: no more moments, so nothing is ever charged.
    assert.equal(replay([0]).total, 0);
    // Even if reports kept arriving, they would all repeat that one moment.
    assert.equal(replay([0, 0, 0, 0]).total, 0);
  });

  it("Edward's device log of 2026-11-14: about 3 minutes of writing now costs under 3 minutes, not 7", () => {
    // Problem opened 11:00:56. He wrote from about 11:01:00 to 11:04:00, one pen stroke about every 10 seconds, then stopped
    // and left it until 11:06. The app sends a heartbeat every 30 s (11:01:26, 11:01:56, ...) carrying the time of the last
    // stroke it has not reported yet. The old rule charged 7 minutes (480 -> 473 minutes left in his log).
    const OPEN = 56; // seconds after 11:00:00
    const strokes: number[] = [];
    for (let s = 60; s <= 240; s += 10) strokes.push(s); // 11:01:00 ... 11:04:00
    const reports: number[] = [];
    let reported = -1;
    for (let tick = OPEN + 30; tick <= 6 * 60 + 30; tick += 30) {
      const latest = strokes.filter((s) => s <= tick).pop();
      if (latest !== undefined && latest > reported) {
        reports.push(latest);
        reported = latest;
      }
    }
    const result = replay(reports);
    assert.equal(result.total, 160, "from the first reported stroke (11:01:20) to the last (11:04:00)");
  });
});

describe("the month resets on the 1st, America/Vancouver", () => {
  // The Vancouver winter offset comes from the runtime's time-zone database: UTC-8 on older data, UTC-7 once BC stays on
  // daylight time (tzdata 2026e does). So these moments stay more than an hour from the boundary and hold either way.
  it("belongs to November until Vancouver midnight, then to December", () => {
    assert.equal(vancouverMonth(at("2026-12-01T06:30:00Z")), "2026-11-01");
    assert.equal(vancouverMonth(at("2026-12-01T09:00:00Z")), "2026-12-01");
  });

  it("uses summer time too (07:00 UTC in July)", () => {
    assert.equal(vancouverMonth(at("2026-08-01T06:59:59Z")), "2026-07-01");
    assert.equal(vancouverMonth(at("2026-08-01T07:00:00Z")), "2026-08-01");
  });

  it("a UTC date of the 1st can still be the previous month in Vancouver", () => {
    assert.equal(vancouverMonth(at("2026-11-01T03:00:00Z")), "2026-10-01");
  });
});

describe("the allowance the app is shown", () => {
  const cap = 8 * 3600;
  const usage = (countedSeconds: number, bonusSeconds = 0) => ({ ...EMPTY_USAGE, countedSeconds, bonusSeconds });

  it("is ok below 80%, low from 80%, used up at 100%", () => {
    assert.equal(allowanceOf("2026-11-01", usage(0), cap).state, "ok");
    assert.equal(allowanceOf("2026-11-01", usage(cap * 0.8 - 1), cap).state, "ok");
    assert.equal(allowanceOf("2026-11-01", usage(cap * 0.8), cap).state, "low");
    assert.equal(allowanceOf("2026-11-01", usage(cap - 1), cap).state, "low");
    assert.equal(allowanceOf("2026-11-01", usage(cap), cap).state, "used_up");
    assert.equal(allowanceOf("2026-11-01", usage(cap + 90), cap).state, "used_up");
  });

  it("reports whole minutes left (rounded down), the month, and never negative time", () => {
    const a = allowanceOf("2026-11-01", usage(cap - 150), cap);
    assert.deepEqual([a.remaining_seconds, a.remaining_minutes, a.month, a.cap_seconds], [150, 2, "2026-11", cap]);
    const over = allowanceOf("2026-11-01", usage(cap + 500), cap);
    assert.deepEqual([over.remaining_seconds, over.remaining_minutes, over.percent_used], [0, 0, 100]);
  });

  it("adds a top-up to the cap for that month", () => {
    const a = allowanceOf("2026-11-01", usage(cap, 3600), cap);
    assert.equal(a.state, "low", "an hour of top-up after running out gives room again (89% of the new total)");
    assert.equal(a.cap_seconds, cap + 3600);
    assert.equal(a.remaining_minutes, 60);
  });
});

describe("migration files", () => {
  it("split into single statements, dropping comment lines", () => {
    const parts = splitStatements("-- a comment\ncreate table a (x int);\n\n-- another\ncreate index i on a (x);\n");
    assert.deepEqual(parts, ["create table a (x int)", "create index i on a (x)"]);
  });
});
