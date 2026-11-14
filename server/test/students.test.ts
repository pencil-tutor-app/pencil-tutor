import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { splitStatements } from "../lib/students-admin.js";
import {
  ACTIVITY_WINDOW_SECONDS,
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

describe("counting time: the union of recent-activity windows", () => {
  it("charges a full window for the first event of a month", () => {
    const r = chargeFor(null, at("2026-11-14T18:00:00Z"));
    assert.equal(r.addedSeconds, ACTIVITY_WINDOW_SECONDS);
    assert.equal(r.coveredUntil.toISOString(), "2026-11-14T18:02:00.000Z");
  });

  it("charges only the new part when the next event arrives inside the covered time", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00Z"));
    const second = chargeFor(first.coveredUntil, at("2026-11-14T18:01:00Z"));
    assert.equal(second.addedSeconds, 60, "60 s of new time, not another 120");
    assert.equal(second.coveredUntil.toISOString(), "2026-11-14T18:03:00.000Z");
  });

  it("charges nothing for a second event in the same second", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00.200Z"));
    const again = chargeFor(first.coveredUntil, at("2026-11-14T18:00:00.900Z"));
    assert.equal(again.addedSeconds, 0);
  });

  it("charges a full window again after a gap longer than the window (the idle time is not counted)", () => {
    const first = chargeFor(null, at("2026-11-14T18:00:00Z"));
    const later = chargeFor(first.coveredUntil, at("2026-11-14T18:30:00Z"));
    assert.equal(later.addedSeconds, 120);
  });

  it("one hour of activity every 60 seconds counts as one hour plus the final window", () => {
    let covered: Date | null = null;
    let total = 0;
    for (let minute = 0; minute <= 60; minute += 1) {
      const charge = chargeFor(covered, new Date(at("2026-11-14T18:00:00Z").getTime() + minute * 60_000));
      total += charge.addedSeconds;
      covered = charge.coveredUntil;
    }
    assert.equal(total, 60 * 60 + 120);
  });

  it("never goes negative when the clock steps back", () => {
    const first = chargeFor(null, at("2026-11-14T18:05:00Z"));
    const back = chargeFor(first.coveredUntil, at("2026-11-14T18:00:00Z"));
    assert.equal(back.addedSeconds, 0);
    assert.equal(back.coveredUntil.getTime(), first.coveredUntil.getTime(), "coverage never shrinks");
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
