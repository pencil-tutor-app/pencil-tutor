import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { MockLanguageModelV4 } from "ai/test";
import { handleAsk } from "../lib/ask.js";
import { handleConsult } from "../lib/consult.js";
import { DatabaseError } from "../lib/db.js";
import {
  ceilingOf,
  clientAddress,
  countText,
  hashAddress,
  maxOutputTokensOf,
  normalizeAddress,
  perIpLimit,
  saltOf,
  speechReserve,
  sttReserve,
  textReserve,
  usdToMicros,
} from "../lib/free-config.js";
import { handleFreeCode } from "../lib/free-code.js";
import { handleHealth } from "../lib/health.js";
import { handleHeartbeat } from "../lib/heartbeat.js";
import { handleMe } from "../lib/me.js";
import type { ModelFactory } from "../lib/models.js";
import { handleMemoryStatus } from "../lib/record/endpoint.js";
import type { RecordStore } from "../lib/record/store.js";
import { handleSpeak } from "../lib/speak.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { codeHash, isValidCode, vancouverMonth } from "../lib/students.js";
import { handleWatch } from "../lib/watch.js";
import {
  askBody,
  captureLogs,
  deps,
  fakeModels,
  fakeVoice,
  freeAndHandStore,
  HAND_TOKEN,
  liveEnv,
  makePng,
  post,
  reply,
  speakBody,
  TEST_MONTH,
  TOKEN,
  watchBody,
} from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SALT = "a-long-random-test-salt-0123456789abcdef";
const freeEnv = (extra: Record<string, string | undefined> = {}) => liveEnv({ FREE_CODE_IP_SALT: SALT, ...extra });
const NOV_1 = "2026-11-01";
const DEC_1 = "2026-12-01";

// A clock the test moves forward.
function clock(startIso = "2026-11-14T18:00:00Z") {
  let t = new Date(startIso).getTime();
  return { now: () => new Date(t), advance: (seconds: number) => void (t += seconds * 1000) };
}

// The first instant of December in Vancouver, found from this runtime's own time-zone data. It is not hard-coded because BC's winter
// offset is a legislated choice that the time-zone database changes (UTC-8 or UTC-7), and the server uses whatever Intl says.
function midnightDec1(): number {
  let t = Date.parse("2026-12-01T05:00:00Z");
  while (vancouverMonth(new Date(t)) !== DEC_1) t += 1000;
  return t;
}
const isoAt = (ms: number) => new Date(ms).toISOString();

const freeCodeRequest = (headers: Record<string, string> = { "x-real-ip": "203.0.113.7" }, method = "POST") =>
  new Request("https://example.test/api/free-code", { method, headers, body: method === "POST" ? "{}" : undefined });

const me = (code: string) => new Request("https://example.test/api/me", { headers: { authorization: `Bearer ${code}` } });

// ---------- the pure parts ----------

describe("free code settings", () => {
  it("the ceiling is US$50 by default, can be set, can be 0 (closed), and a bad value is NOT 'no limit'", () => {
    assert.deepEqual([ceilingOf({}).usd, ceilingOf({}).source], [50, "default"]);
    assert.deepEqual([ceilingOf({ FREE_MONTHLY_CEILING_USD: "12.5" }).usd, ceilingOf({ FREE_MONTHLY_CEILING_USD: "12.5" }).micros], [12.5, 12_500_000]);
    assert.equal(ceilingOf({ FREE_MONTHLY_CEILING_USD: "0" }).micros, 0);
    for (const bad of ["abc", "-3", "NaN", "Infinity"]) {
      const c = ceilingOf({ FREE_MONTHLY_CEILING_USD: bad });
      assert.deepEqual([c.usd, c.source], [50, "invalid_env_using_default"], bad);
    }
  });

  it("the per-address limit is 3 by default, a whole number from 1 to 100 when set", () => {
    assert.equal(perIpLimit({}).limit, 3);
    assert.equal(perIpLimit({ FREE_CODE_PER_IP_PER_DAY: "5" }).limit, 5);
    for (const bad of ["0", "-1", "2.5", "x", "101"]) assert.deepEqual([perIpLimit({ FREE_CODE_PER_IP_PER_DAY: bad }).limit, perIpLimit({ FREE_CODE_PER_IP_PER_DAY: bad }).source], [3, "invalid_env_using_default"], bad);
  });

  it("the salt must be set and at least 16 characters", () => {
    assert.deepEqual(saltOf({}), { ok: false, reason: "ip_salt_not_set" });
    assert.deepEqual(saltOf({ FREE_CODE_IP_SALT: "   " }), { ok: false, reason: "ip_salt_not_set" });
    assert.deepEqual(saltOf({ FREE_CODE_IP_SALT: "short" }), { ok: false, reason: "ip_salt_too_short" });
    assert.deepEqual(saltOf({ FREE_CODE_IP_SALT: SALT }), { ok: true, salt: SALT });
  });

  it("rounds money up to whole millionths, without float fuzz", () => {
    assert.equal(usdToMicros(0.008), 8000);
    assert.equal(usdToMicros((0.0045 / 60) * 2), 150, "two seconds of speech-to-text");
    assert.equal(usdToMicros(0.0000001), 1, "a tenth of a millionth still counts as one");
    assert.equal(usdToMicros(0), 0);
  });

  it("maxOutputTokens defaults to 3,000 and ignores nonsense", () => {
    assert.equal(maxOutputTokensOf({}), 3000);
    assert.equal(maxOutputTokensOf({ FREE_MAX_OUTPUT_TOKENS: "1500" }), 1500);
    assert.equal(maxOutputTokensOf({ FREE_MAX_OUTPUT_TOKENS: "5" }), 3000);
    assert.equal(maxOutputTokensOf({ FREE_MAX_OUTPUT_TOKENS: "lots" }), 3000);
  });

  it("health reports the settings and never the salt", async () => {
    const off = (await reply(handleHealth(new Request("https://example.test/api/health"), {}))).json.free_codes;
    assert.deepEqual(off, { creation: "off", reason: "ip_salt_not_set", ceiling_usd: 50, ceiling_source: "default", per_ip_per_day: 3 });
    const res = handleHealth(new Request("https://example.test/api/health"), { FREE_CODE_IP_SALT: SALT });
    const text = await res.text();
    assert.ok(!text.includes(SALT), "the salt is not in the health reply");
    assert.equal((JSON.parse(text) as { free_codes: { creation: string } }).free_codes.creation, "on");
  });
});

describe("network addresses", () => {
  it("keeps an IPv4 address and groups an IPv6 address by its first 64 bits", () => {
    assert.equal(normalizeAddress("203.0.113.7"), "203.0.113.7");
    assert.equal(normalizeAddress("2001:db8:aaaa:bbbb:1:2:3:4"), "2001:db8:aaaa:bbbb::/64");
    assert.equal(normalizeAddress("2001:db8:aaaa:bbbb:ffff:ffff:ffff:ffff"), normalizeAddress("2001:DB8:AAAA:BBBB::1"), "same /64, same bucket");
    assert.notEqual(normalizeAddress("2001:db8:aaaa:bbbc::1"), normalizeAddress("2001:db8:aaaa:bbbb::1"));
    assert.equal(normalizeAddress("::1"), "0:0:0:0::/64");
  });

  it("treats an IPv4-mapped IPv6 address as the IPv4 address, and refuses text that is not an address", () => {
    assert.equal(normalizeAddress("::ffff:203.0.113.7"), "203.0.113.7");
    assert.equal(normalizeAddress("::ffff:cb00:7107"), "203.0.113.7");
    for (const bad of ["", "not an ip", "999.1.1.1", "1.2.3", "2001:db8::zz"]) assert.equal(normalizeAddress(bad), null, bad);
  });

  it("reads x-vercel-forwarded-for, then x-real-ip, then the first x-forwarded-for entry; skips a header that is not an address", () => {
    const h = (o: Record<string, string>) => new Headers(o);
    assert.equal(clientAddress(h({ "x-vercel-forwarded-for": "198.51.100.1", "x-real-ip": "198.51.100.2", "x-forwarded-for": "198.51.100.3" })), "198.51.100.1");
    assert.equal(clientAddress(h({ "x-real-ip": "198.51.100.2", "x-forwarded-for": "198.51.100.3" })), "198.51.100.2");
    assert.equal(clientAddress(h({ "x-forwarded-for": "198.51.100.3, 10.0.0.1, 10.0.0.2" })), "198.51.100.3");
    assert.equal(clientAddress(h({ "x-vercel-forwarded-for": "garbage", "x-real-ip": "198.51.100.2" })), "198.51.100.2");
    assert.equal(clientAddress(h({})), null);
  });

  it("hashes with a key: 32 hex characters, different for a different salt, and the address is not in it", () => {
    const a = hashAddress("203.0.113.7", SALT);
    assert.match(a, /^[0-9a-f]{32}$/);
    assert.equal(a, hashAddress("203.0.113.7", SALT));
    assert.notEqual(a, hashAddress("203.0.113.7", `${SALT}-other`));
    assert.notEqual(a, hashAddress("203.0.113.8", SALT));
    assert.ok(!a.includes("203"));
  });
});

describe("the worst case reserved for one paid call", () => {
  const at = new Date("2026-11-14T18:00:00Z");

  it("a text call reserves two attempts of (25,000 input tokens + the output cap) at the model's own price", () => {
    // gpt-6-luna: $0.10 in, $0.50 out per million. (25,000 x 0.1 + 3,000 x 0.5) / 1e6 = $0.004 an attempt.
    assert.deepEqual(textReserve("gpt-6-luna", at, 3000), { perAttempt: 4000, total: 8000 });
    // gpt-6.1-sol: $2 in, $10 out. (25,000 x 2 + 3,000 x 10) / 1e6 = $0.08 an attempt.
    assert.deepEqual(textReserve("gpt-6.1-sol", at, 3000), { perAttempt: 80_000, total: 160_000 });
    assert.deepEqual(textReserve("gpt-6-luna", at, 3000, 1), { perAttempt: 4000, total: 4000 });
  });

  it("a model with no price has no bound", () => {
    assert.equal(textReserve("some-new-model", at, 3000), undefined);
    assert.equal(sttReserve("some-new-stt", 1000), undefined);
    assert.equal(speechReserve("some-new-tts", 100), undefined);
  });

  it("speech to text reserves the recording's bytes at the floor rate, speech reserves 600 characters a minute", () => {
    // 300,000 bytes / 800 B/s = 375 s = 6.25 min x $0.0045 = $0.028125 an attempt.
    assert.deepEqual(sttReserve("gpt-transcribe", 300_000), { perAttempt: 28_125, total: 56_250 });
    // 600 characters at 600 a minute = 1 minute x $0.015.
    assert.deepEqual(speechReserve("gpt-4o-mini-tts", 600), { perAttempt: 15_000, total: 30_000 });
  });

  it("counts a failure at the whole reserve, a reply with usage at its estimate, and a reply without usage at one attempt", () => {
    const reserve = { perAttempt: 4000, total: 8000 };
    const usage = { model_ms: 1, input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, reasoning_tokens: null, est_cost_usd: 0.000006, cost_basis: "estimated" as const };
    assert.deepEqual(countText(usage, null, reserve), { micros: 6, basis: "estimated" });
    assert.deepEqual(countText({ ...usage, est_cost_usd: null, cost_basis: "no_price" }, null, reserve), { micros: 4000, basis: "reserve_kept_no_usage", detail: "no_price" });
    assert.deepEqual(countText(undefined, null, reserve), { micros: 4000, basis: "reserve_kept_no_usage", detail: "no_usage" });
    assert.deepEqual(countText(undefined, "provider_http_503", reserve), { micros: 8000, basis: "reserve_kept_failed", detail: "provider_http_503" });
  });
});

// ---------- POST /api/free-code ----------

describe("POST /api/free-code", () => {
  it("makes a free code: 8 hours a month, live voice off, origin free, and it works in the app's other calls", async () => {
    const store = new MemoryStudentStore();
    const d = deps(freeEnv(), undefined, { store });
    const r = await reply(await handleFreeCode(freeCodeRequest(), d));
    assert.equal(r.status, 200);
    const code = String(r.json.code);
    assert.ok(isValidCode(code), "the code has the usual shape");
    assert.equal(r.json.cap_minutes, 480);
    assert.deepEqual(store.codesOf("free"), [code]);
    assert.deepEqual(store.codesOf("admin"), []);

    const lookup = await store.lookup(code, TEST_MONTH);
    assert.deepEqual([lookup?.origin, lookup?.planLive, lookup?.capSeconds, lookup?.disabled], ["free", false, 28_800, false]);

    const info = await reply(await handleMe(me(code), d));
    assert.equal(info.status, 200);
    assert.deepEqual(info.json.plan, { live: false, cap_minutes: 480 });
    assert.deepEqual(info.json.free, { full: false });
    assert.equal((info.json.allowance as Record<string, unknown>).remaining_minutes, 480);
  });

  it("gives every caller a different code", async () => {
    const store = new MemoryStudentStore();
    const seen = new Set<string>();
    for (let i = 0; i < 6; i += 1) {
      const r = await reply(await handleFreeCode(freeCodeRequest({ "x-real-ip": `203.0.113.${10 + i}` }), deps(freeEnv(), undefined, { store })));
      seen.add(String(r.json.code));
    }
    assert.equal(seen.size, 6);
  });

  it("answers 405 to GET, and 503 free_codes_unavailable while the salt is not set or too short, creating nothing", async () => {
    const store = new MemoryStudentStore();
    assert.equal((await handleFreeCode(freeCodeRequest({ "x-real-ip": "203.0.113.7" }, "GET"), deps(freeEnv(), undefined, { store }))).status, 405);
    const none = await reply(await handleFreeCode(freeCodeRequest(), deps(liveEnv(), undefined, { store })));
    assert.deepEqual([none.status, none.json.error, none.json.reason], [503, "free_codes_unavailable", "ip_salt_not_set"]);
    const short = await reply(await handleFreeCode(freeCodeRequest(), deps(liveEnv({ FREE_CODE_IP_SALT: "tiny" }), undefined, { store })));
    assert.deepEqual([short.status, short.json.reason], [503, "ip_salt_too_short"]);
    assert.deepEqual(store.codesOf("free"), []);
    assert.equal(logs.lines.at(-1)?.outcome, "free_codes_unavailable:ip_salt_too_short");
  });

  it("allows 3 codes per address in 24 hours, refuses the 4th with 429 and Retry-After, and the refusal writes nothing", async () => {
    const store = new MemoryStudentStore();
    const c = clock();
    const d = deps(freeEnv(), undefined, { store, now: c.now });
    for (let i = 0; i < 3; i += 1) {
      assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 200, `code ${i + 1}`);
      c.advance(60);
    }
    const hash = hashAddress("203.0.113.7", SALT);
    assert.equal(store.slotCount(hash), 3);
    const refused = await handleFreeCode(freeCodeRequest(), d);
    assert.equal(refused.status, 429);
    const body = (await refused.json()) as Record<string, unknown>;
    assert.deepEqual([body.error, body.reason], ["rate_limited", "ip_limit_reached"]);
    const retry = Number(refused.headers.get("retry-after"));
    // The oldest creation was 180 s ago, so it ages out in 24 h minus 180 s.
    assert.equal(retry, 24 * 3600 - 180);
    assert.equal(store.slotCount(hash), 3, "a refusal adds nothing");
    assert.equal(store.codesOf("free").length, 3, "and creates no student");
    // Hammering does not extend the lock-out.
    for (let i = 0; i < 5; i += 1) assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 429);
    assert.equal(store.slotCount(hash), 3);
  });

  it("is a rolling window: still refused at 23 h 59 m, allowed again once the oldest creation is 24 hours old", async () => {
    const store = new MemoryStudentStore();
    const c = clock();
    const d = deps(freeEnv(), undefined, { store, now: c.now });
    for (let i = 0; i < 3; i += 1) assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 200);
    c.advance(24 * 3600 - 1);
    assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 429, "one second short of 24 hours");
    c.advance(2);
    assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 200, "the three old creations have aged out together");
  });

  it("limits per address: another address is unaffected, and so are two addresses in the same IPv6 /64 (they share a bucket)", async () => {
    const store = new MemoryStudentStore();
    const d = deps(freeEnv(), undefined, { store });
    for (let i = 0; i < 3; i += 1) await handleFreeCode(freeCodeRequest(), d);
    assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 429);
    assert.equal((await handleFreeCode(freeCodeRequest({ "x-real-ip": "198.51.100.9" }), d)).status, 200, "a different network");
    for (let i = 0; i < 3; i += 1) await handleFreeCode(freeCodeRequest({ "x-forwarded-for": `2001:db8:1:2:${i}::1` }), d);
    assert.equal((await handleFreeCode(freeCodeRequest({ "x-forwarded-for": "2001:db8:1:2:ffff::9" }), d)).status, 429, "same /64, same bucket");
    assert.equal((await handleFreeCode(freeCodeRequest({ "x-forwarded-for": "2001:db8:1:3::1" }), d)).status, 200, "another /64");
  });

  it("honours FREE_CODE_PER_IP_PER_DAY", async () => {
    const store = new MemoryStudentStore();
    const d = deps(freeEnv({ FREE_CODE_PER_IP_PER_DAY: "1" }), undefined, { store });
    assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 200);
    assert.equal((await handleFreeCode(freeCodeRequest(), d)).status, 429);
  });

  it("refuses 400 when there is no network address to count", async () => {
    const store = new MemoryStudentStore();
    const r = await reply(await handleFreeCode(freeCodeRequest({}), deps(freeEnv(), undefined, { store })));
    assert.deepEqual([r.status, r.json.reason], [400, "no_client_ip"]);
    assert.deepEqual(store.codesOf("free"), []);
  });

  it("refuses 403 free_tutoring_full when the ceiling is reached, and a full month burns nobody's slot", async () => {
    const store = new MemoryStudentStore();
    store.setFreeSpend(TEST_MONTH, 50_000_000);
    const r = await reply(await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store })));
    assert.deepEqual([r.status, r.json.error], [403, "free_tutoring_full"]);
    assert.equal(store.slotCount(hashAddress("203.0.113.7", SALT)), 0);
    assert.deepEqual(store.codesOf("free"), []);
    assert.equal(logs.lines.at(-1)?.outcome, "free_code_refused:ceiling_reached");
  });

  it("FREE_MONTHLY_CEILING_USD=0 closes free codes, and an invalid value falls back to US$50 with a warning", async () => {
    const store = new MemoryStudentStore();
    const closed = await handleFreeCode(freeCodeRequest(), deps(freeEnv({ FREE_MONTHLY_CEILING_USD: "0" }), undefined, { store }));
    assert.equal(closed.status, 403);
    const bad = await handleFreeCode(freeCodeRequest(), deps(freeEnv({ FREE_MONTHLY_CEILING_USD: "lots" }), undefined, { store }));
    assert.equal(bad.status, 200, "an unreadable ceiling is not 'closed' and not 'unlimited'");
    assert.ok(logs.lines.some((l) => l.outcome === "free_setting_ignored"));
  });

  it("answers 503 database_unavailable when the database is down, and makes nothing", async () => {
    const store = new MemoryStudentStore();
    store.failWith = new DatabaseError("db_timeout");
    const r = await reply(await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store })));
    assert.deepEqual([r.status, r.json.error], [503, "database_unavailable"]);
  });

  it("gives the slot back when the insert is KNOWN to have failed, and keeps it when the outcome is unknown", async () => {
    const hash = hashAddress("203.0.113.7", SALT);

    const known = new MemoryStudentStore();
    known.failCreateWith = new DatabaseError("db_53100"); // an SQLSTATE: the database refused the statement
    const k = await reply(await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store: known })));
    assert.deepEqual([k.status, k.json.error], [503, "free_codes_unavailable"]);
    assert.equal(known.slotCount(hash), 0, "the slot was released");
    assert.equal(logs.lines.at(-1)?.outcome, "free_code_insert_failed:db_53100");
    known.failCreateWith = null;
    assert.equal((await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store: known }))).status, 200, "and the family can try again");

    const unknown = new MemoryStudentStore();
    unknown.failCreateWith = new DatabaseError("db_timeout"); // the insert may or may not have happened
    const u = await reply(await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store: unknown })));
    assert.equal(u.status, 503);
    assert.equal(unknown.slotCount(hash), 1, "the slot stays used, because a code may exist");
    assert.equal(logs.lines.at(-1)?.outcome, "free_code_insert_outcome_unknown:db_timeout");
  });

  it("deletes address hashes untouched for two days when it makes a code", async () => {
    const store = new MemoryStudentStore();
    const c = clock();
    const d = deps(freeEnv(), undefined, { store, now: c.now });
    await handleFreeCode(freeCodeRequest({ "x-real-ip": "198.51.100.50" }), d);
    const old = hashAddress("198.51.100.50", SALT);
    assert.equal(store.slotCount(old), 1);
    c.advance(47 * 3600);
    await handleFreeCode(freeCodeRequest({ "x-real-ip": "198.51.100.51" }), d);
    assert.equal(store.slotCount(old), 1, "47 hours is not stale yet");
    c.advance(2 * 3600);
    await handleFreeCode(freeCodeRequest({ "x-real-ip": "198.51.100.52" }), d);
    assert.equal(store.slotCount(old), 0, "49 hours is");
    assert.ok(logs.lines.some((l) => l.ip_rows_purged === 1));
  });

  it("logs why on every branch, with no code and no address, and never an address hash next to a code", async () => {
    const store = new MemoryStudentStore();
    const d = deps(freeEnv(), undefined, { store });
    const made = await reply(await handleFreeCode(freeCodeRequest(), d));
    for (let i = 0; i < 3; i += 1) await handleFreeCode(freeCodeRequest(), d);
    await handleFreeCode(freeCodeRequest({ "x-real-ip": "198.51.100.77" }, "GET"), d);

    const all = logs.raw.join("\n");
    assert.ok(!all.includes(String(made.json.code)), "the code is never logged");
    assert.ok(!all.includes("203.0.113.7") && !all.includes("198.51.100.77"), "the address is never logged");
    assert.ok(!all.includes(SALT), "the salt is never logged");
    assert.ok(!all.includes(hashAddress("203.0.113.7", SALT)), "not even the whole hash");

    const success = logs.lines.find((l) => l.outcome === "ok");
    assert.equal(success?.reason, "free_code_created");
    assert.equal(success?.student, codeHash(String(made.json.code)), "the code's log id matches `codes list`");
    assert.equal(success?.origin, "free");
    assert.equal(success?.ip_slot, "1/3");
    assert.ok(!("ip_hash" in (success ?? {})), "the creation line carries no address hash");

    const refusal = logs.lines.find((l) => l.outcome === "free_code_refused:ip_limit_reached");
    assert.match(String(refusal?.ip_hash), /^[0-9a-f]{8}$/);
    assert.ok(!("student" in (refusal ?? {})), "the refusal line carries no code");
    for (const line of logs.lines) assert.ok(!("ip_hash" in line && "student" in line), "no line holds both");
    assert.ok(logs.lines.every((l) => typeof l.outcome === "string" && l.outcome.length > 0), "every line says what was decided");
  });

  it("does not touch hand-made codes: they have no address limit and are listed apart", async () => {
    const store = new MemoryStudentStore();
    store.add(HAND_TOKEN);
    for (let i = 0; i < 3; i += 1) await handleFreeCode(freeCodeRequest(), deps(freeEnv(), undefined, { store }));
    assert.deepEqual(store.codesOf("admin"), [HAND_TOKEN]);
    assert.equal(store.codesOf("free").length, 3);
  });
});

// ---------- the ceiling, in the gate ----------

describe("a free code when free tutoring is full", () => {
  const FULL = 50_000_000;
  const record = { status: async () => ({ consent: null, notes: 0, recent: [] }) } as unknown as RecordStore;
  const authed = (path: string, method = "GET") => new Request(`https://example.test${path}`, { method, headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" }, body: method === "POST" ? "{}" : undefined });

  function full() {
    const { store } = freeAndHandStore();
    store.setFreeSpend(TEST_MONTH, FULL);
    return store;
  }
  const kind = (r: { status: number; json: Record<string, unknown> }) => [r.status, r.json.error];

  it("is refused 403 free_tutoring_full on watch, ask, consult, speak (notices too) and heartbeat, before any model or voice is called", async () => {
    const store = full();
    const voice = fakeVoice([new Uint8Array([1, 0])]);
    const d = deps(freeEnv({ ELEVENLABS_API_KEY: "xi-test" }), undefined, { store, voice: voice.gateway });
    assert.deepEqual(kind(await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" })), d))), [403, "free_tutoring_full"]);
    assert.deepEqual(kind(await reply(await handleAsk(post("/api/ask", askBody({ problem_id: "u3-01" })), d))), [403, "free_tutoring_full"]);
    const consultBody = { session_id: "s", problem_id: "u3-01", image_png_base64: makePng(800, 600), question: "is this right", recent: [] };
    assert.deepEqual(kind(await reply(await handleConsult(post("/api/consult", consultBody), d))), [403, "free_tutoring_full"]);
    assert.deepEqual(kind(await reply(await handleSpeak(post("/api/speak", speakBody()), d))), [403, "free_tutoring_full"]);
    for (const purpose of ["allowance_low", "allowance_used_up"]) {
      assert.deepEqual(kind(await reply(await handleSpeak(post("/api/speak", { session_id: "s", purpose }), d))), [403, "free_tutoring_full"], `${purpose} notice`);
    }
    assert.deepEqual(kind(await reply(await handleHeartbeat(post("/api/heartbeat", { session_id: "s", problem_id: "u3-01" }), d))), [403, "free_tutoring_full"]);
    assert.equal(voice.calls.length, 0, "no paid voice was called");
    assert.equal(logs.lines.at(-1)?.outcome, "free_tutoring_full");
  });

  it("still answers /api/me (with free.full true, so the app can say so kindly) and /api/memory (a family can always withdraw)", async () => {
    const store = full();
    const d = deps(freeEnv(), undefined, { store });
    d.record = record;
    const info = await reply(await handleMe(authed("/api/me"), d));
    assert.equal(info.status, 200);
    assert.deepEqual(info.json.free, { full: true });
    assert.equal((await handleMemoryStatus(authed("/api/memory"), d)).status, 200);
  });

  it("never touches a hand-made code, whatever the free month's total", async () => {
    const store = full();
    const { models } = fakeModels(JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null }));
    const d = deps(freeEnv(), models, { store });
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" }), HAND_TOKEN), d));
    assert.equal(r.status, 200);
    const hand = await reply(await handleMe(new Request("https://example.test/api/me", { headers: { authorization: `Bearer ${HAND_TOKEN}` } }), d));
    assert.equal("free" in hand.json, false, "a hand-made code is told nothing about free tutoring");
    assert.equal(store.freeMonth(TEST_MONTH).micros, FULL, "and its calls add nothing to the free total");
  });

  it("reopens on the 1st (Vancouver): refused on Nov 30 at 23:59:50, answered a few seconds after midnight", async () => {
    const store = full();
    const { models } = fakeModels(JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null }));
    const c = clock(isoAt(midnightDec1() - 10_000)); // 23:59:50 on Nov 30 in Vancouver
    const d = deps(freeEnv(), models, { store, now: c.now });
    assert.equal((await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" })), d)).status, 403);
    c.advance(11); // 00:00:01 on Dec 1
    assert.equal((await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" })), d)).status, 200);
    assert.equal(store.freeMonth(NOV_1).micros, FULL, "November is untouched");
    assert.ok(store.freeMonth(DEC_1).micros > 0 && store.freeMonth(DEC_1).micros < 100, "December has the new call");
  });

  it("never gets live voice, even if the row says it may", async () => {
    const { store } = freeAndHandStore({ planLive: true });
    const info = await reply(await handleMe(authed("/api/me"), deps(freeEnv(), undefined, { store })));
    assert.deepEqual(info.json.plan, { live: false, cap_minutes: 480 });
  });
});

// ---------- reserve, run, settle ----------

const DECISION = JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null });
type Tokens = { input: number; output: number } | "none";

function language(options: { text?: string; usage?: Tokens; before?: () => Promise<void> | void; throws?: boolean; seen?: { maxOutputTokens?: (number | undefined)[] } } = {}) {
  return new MockLanguageModelV4({
    doGenerate: async (call) => {
      options.seen?.maxOutputTokens?.push(call.maxOutputTokens);
      await options.before?.();
      if (options.throws) throw new Error("the provider exploded");
      const u = options.usage ?? { input: 10, output: 10 };
      const usage =
        u === "none"
          ? {
              inputTokens: { total: undefined, noCache: undefined, cacheRead: undefined, cacheWrite: undefined },
              outputTokens: { total: undefined, text: undefined, reasoning: undefined },
            }
          : {
              inputTokens: { total: u.input, noCache: u.input, cacheRead: 0, cacheWrite: 0 },
              outputTokens: { total: u.output, text: u.output, reasoning: 0 },
            };
      return { content: [{ type: "text" as const, text: options.text ?? DECISION }], finishReason: { unified: "stop" as const, raw: "stop" }, usage, warnings: [] };
    },
  });
}

function factory(lm: MockLanguageModelV4, extra: { seconds?: number | undefined; transcript?: string; speechBytes?: Uint8Array } = {}): ModelFactory {
  return {
    language: () => lm,
    transcription: () => ({
      specificationVersion: "v4",
      provider: "fake",
      modelId: "fake-stt",
      doGenerate: async () => ({
        text: extra.transcript ?? "what do I do with the minus sign",
        segments: [],
        language: "en",
        durationInSeconds: "seconds" in extra ? extra.seconds : 2,
        warnings: [],
        response: { timestamp: new Date(), modelId: "fake-stt" },
      }),
    }),
    speech: (cfg) => ({
      specificationVersion: "v4",
      provider: "fake",
      modelId: cfg.model,
      doGenerate: async () => ({ audio: extra.speechBytes ?? new Uint8Array(48_000), warnings: [], response: { timestamp: new Date(), modelId: cfg.model } }),
    }),
  };
}

const watchOnce = (d: ReturnType<typeof deps>, code = TOKEN) => handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" }), code), d);

describe("a free code's paid calls are reserved before and settled after", () => {
  it("watch: counts the call's own estimated cost (reserve 8,000 millionths, settled down to 6) and logs both", async () => {
    const { store } = freeAndHandStore();
    const seen = { maxOutputTokens: [] as (number | undefined)[] };
    const r = await reply(await watchOnce(deps(freeEnv(), factory(language({ seen })), { store })));
    assert.equal(r.status, 200);
    assert.deepEqual(store.freeMonth(TEST_MONTH), { micros: 6, elevenChars: 0, calls: 1 });
    assert.deepEqual(seen.maxOutputTokens, [3000], "the model was given the output cap");
    const line = logs.lines.at(-1)!;
    assert.deepEqual([line.free_watch_reserved_usd, line.free_watch_counted_usd, line.free_watch_basis, line.free_month_usd], [0.008, 0.000006, "estimated", 0.000006]);
    assert.ok(!logs.raw.join("\n").includes(TOKEN), "the code is not logged");
  });

  it("a hand-made code is not reserved, not counted, not capped and not price-checked", async () => {
    const { store } = freeAndHandStore();
    const seen = { maxOutputTokens: [] as (number | undefined)[] };
    const r = await watchOnce(deps(freeEnv({ WATCH_MODEL: "some-new-model" }), factory(language({ seen })), { store }), HAND_TOKEN);
    assert.equal(r.status, 200);
    assert.deepEqual(store.freeMonth(TEST_MONTH), { micros: 0, elevenChars: 0, calls: 0 });
    assert.deepEqual(seen.maxOutputTokens, [undefined], "no output cap is sent for a hand-made code");
  });

  it("parallel calls cannot pass the ceiling: with room for one reserve, the second is refused while the first is in flight", async () => {
    const { store } = freeAndHandStore();
    let release!: () => void;
    const hold = new Promise<void>((resolve) => (release = resolve));
    const d = deps(freeEnv({ FREE_MONTHLY_CEILING_USD: "0.01" }), factory(language({ before: () => hold })), { store });
    const first = watchOnce(d);
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(store.freeMonth(TEST_MONTH).micros, 8000, "the first call's worst case is already counted");
    const second = await reply(await watchOnce(d));
    assert.deepEqual([second.status, second.json.error], [403, "free_tutoring_full"]);
    assert.equal(logs.lines.at(-1)?.outcome, "free_tutoring_full:watch_reserve_refused");
    release();
    assert.equal((await first).status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 6, "settled to the real cost");
    assert.equal((await watchOnce(d)).status, 200, "and there is room again");
  });

  it("a failed call keeps its whole reserve counted (it may have been billed)", async () => {
    const { store } = freeAndHandStore();
    const r = await reply(await watchOnce(deps(freeEnv(), factory(language({ throws: true })), { store })));
    assert.equal(r.status, 502);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 8000);
    assert.equal(logs.lines.at(-1)?.free_watch_basis, "reserve_kept_failed:provider_error_Error");
  });

  it("a reply with no usage keeps one attempt's bound counted", async () => {
    const { store } = freeAndHandStore();
    const r = await watchOnce(deps(freeEnv(), factory(language({ usage: "none" })), { store }));
    assert.equal(r.status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 4000);
    assert.equal(logs.lines.at(-1)?.free_watch_basis, "reserve_kept_no_usage:no_usage");
  });

  it("a model with no price cannot be bounded, so a free code is refused 503 and nothing is called", async () => {
    const { store } = freeAndHandStore();
    let calls = 0;
    const lm = language({ before: () => void (calls += 1) });
    const r = await reply(await watchOnce(deps(freeEnv({ WATCH_MODEL: "some-new-model" }), factory(lm), { store })));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [503, "bad_config", "free_model_unpriced"]);
    assert.equal(calls, 0);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 0);
  });

  it("fails closed: when the meter cannot be written, a free code's call is not made", async () => {
    const { store } = freeAndHandStore();
    let calls = 0;
    const lm = language({ before: () => void (calls += 1) });
    const original = store.reserveFreeSpend.bind(store);
    store.reserveFreeSpend = async () => {
      throw new DatabaseError("db_timeout");
    };
    const r = await reply(await watchOnce(deps(freeEnv(), factory(lm), { store })));
    assert.deepEqual([r.status, r.json.error], [503, "database_unavailable"]);
    assert.equal(calls, 0);
    store.reserveFreeSpend = original;
  });

  it("when settling fails the reserve stays counted, and the failure is logged, not hidden", async () => {
    const { store } = freeAndHandStore();
    store.settleFreeSpend = async () => {
      throw new DatabaseError("db_timeout");
    };
    const r = await watchOnce(deps(freeEnv(), factory(language()), { store }));
    assert.equal(r.status, 200, "the student still gets the answer");
    assert.equal(store.freeMonth(TEST_MONTH).micros, 8000);
    const failure = logs.lines.find((l) => l.outcome === "free_spend_not_recorded");
    assert.deepEqual([failure?.reason, failure?.reserved_usd, failure?.would_count_usd], ["db_timeout", 0.008, 0.000006]);
  });

  it("a call that crosses midnight is settled in the month it was reserved in", async () => {
    const { store } = freeAndHandStore();
    const c = clock(isoAt(midnightDec1() - 2000)); // 23:59:58 on Nov 30 in Vancouver
    const d = deps(freeEnv(), factory(language({ before: () => c.advance(5) })), { store, now: c.now });
    assert.equal((await watchOnce(d)).status, 200);
    assert.equal(vancouverMonth(c.now()), DEC_1, "the clock really did pass midnight while the call was in flight");
    assert.deepEqual([store.freeMonth(NOV_1).micros, store.freeMonth(DEC_1).micros], [6, 0]);
  });

  it("ask: counts speech to text (the provider's duration) plus the answer, and gives the answer's share back when nothing was heard", async () => {
    const { store } = freeAndHandStore();
    // 2 seconds of audio at $0.0045 a minute = 150 millionths, plus the answer's 6.
    const ok = await handleAsk(post("/api/ask", askBody({ problem_id: "u3-01" })), deps(freeEnv(), factory(language({ text: "Try the x terms first." })), { store }));
    assert.equal(ok.status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 156);

    const quiet = await handleAsk(post("/api/ask", askBody({ problem_id: "u3-01" })), deps(freeEnv(), factory(language(), { transcript: "" }), { store }));
    assert.equal(quiet.status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 156 + 150, "only the speech-to-text was counted; the answer never ran");
  });

  it("ask: with no duration from the provider, one attempt's bound for that recording stays counted", async () => {
    const { store } = freeAndHandStore();
    await handleAsk(post("/api/ask", askBody({ problem_id: "u3-01" })), deps(freeEnv(), factory(language(), { seconds: undefined }), { store }));
    // "fake m4a bytes" is 14 bytes: 14 / 800 B/s = 0.0175 s = $0.0000013 an attempt, which rounds up to 2 millionths, plus the answer's 6.
    assert.equal(store.freeMonth(TEST_MONTH).micros, 2 + 6);
    assert.equal(logs.lines.at(-1)?.free_ask_basis, "reserve_kept_no_usage:stt_no_duration");
  });

  it("ask: a free code's recording may be at most 300 KB; a hand-made code's limit is still 2.5 MB", async () => {
    const { store } = freeAndHandStore();
    const big = (bytes: number) => askBody({ problem_id: "u3-01", audio_base64: Buffer.alloc(bytes, 1).toString("base64") });
    const d = deps(freeEnv(), factory(language()), { store });
    const free = await reply(await handleAsk(post("/api/ask", big(300_001)), d));
    assert.deepEqual([free.status, free.json.reason], [422, "audio_over_300_KB_for_free_code"]);
    assert.equal((await handleAsk(post("/api/ask", big(300_000)), d)).status, 200);
    assert.equal((await handleAsk(post("/api/ask", big(300_001), HAND_TOKEN), d)).status, 200);
  });

  it("consult: counted like a watch", async () => {
    const { store } = freeAndHandStore();
    const body = { session_id: "s", problem_id: "u3-01", image_png_base64: makePng(800, 600), question: "is this right", recent: [] };
    const r = await handleConsult(post("/api/consult", body), deps(freeEnv(), factory(language({ text: "Line one is written." })), { store }));
    assert.equal(r.status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 6);
  });

  it("speak: the OpenAI fallback voice is counted from the audio it returned (1 second = 250 millionths)", async () => {
    const { store } = freeAndHandStore();
    const r = await handleSpeak(post("/api/speak", speakBody()), deps(freeEnv(), factory(language(), { speechBytes: new Uint8Array(48_000) }), { store }));
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("x-voice-provider"), "openai");
    assert.equal(store.freeMonth(TEST_MONTH).micros, 250);
  });

  it("speak: ElevenLabs adds no dollars, only its characters to the information counter", async () => {
    const { store } = freeAndHandStore();
    const voice = fakeVoice([new Uint8Array([1, 0, 2, 0]), new Uint8Array([3, 0])]);
    const text = "Take another look at line two.";
    const r = await handleSpeak(post("/api/speak", speakBody({ text })), deps(freeEnv({ ELEVENLABS_API_KEY: "xi-test" }), undefined, { store, voice: voice.gateway }));
    assert.equal(r.status, 200);
    await r.arrayBuffer(); // drain the stream
    assert.deepEqual(store.freeMonth(TEST_MONTH), { micros: 0, elevenChars: text.length, calls: 0 });
  });

  it("speak: a hand-made code's ElevenLabs characters are not added to the free counter", async () => {
    const { store } = freeAndHandStore();
    const voice = fakeVoice([new Uint8Array([1, 0])]);
    const r = await handleSpeak(post("/api/speak", speakBody(), HAND_TOKEN), deps(freeEnv({ ELEVENLABS_API_KEY: "xi-test" }), undefined, { store, voice: voice.gateway }));
    await r.arrayBuffer();
    assert.deepEqual(store.freeMonth(TEST_MONTH), { micros: 0, elevenChars: 0, calls: 0 });
  });

  it("a call that costs more than its reserve is counted in full, and one warning is logged the moment the total crosses the ceiling", async () => {
    const { store } = freeAndHandStore();
    // With the output cap at 100 tokens a luna call reserves 2 x (25,000 x 0.1 + 100 x 0.5) / 1e6 = $0.0051, which fits under $50.
    store.setFreeSpend(TEST_MONTH, 49_994_000);
    // The model reports 2,000,000 input tokens (far over the assumed bound): $0.200005.
    const d = deps(freeEnv({ FREE_MAX_OUTPUT_TOKENS: "100" }), factory(language({ usage: { input: 2_000_000, output: 10 } })), { store });
    const r = await watchOnce(d);
    assert.equal(r.status, 200);
    assert.equal(store.freeMonth(TEST_MONTH).micros, 49_994_000 + 200_005, "the real cost is added in full, even past the ceiling");
    const reached = logs.lines.find((l) => l.outcome === "free_ceiling_reached");
    assert.equal(reached?.reason, "after_watch");
    assert.equal(reached?.free_ceiling_usd, 50);
    assert.equal((await watchOnce(d)).status, 403, "and from then on free tutoring is full");
  });
});

describe("free codes and the rest of the server stay separate", () => {
  it("a MemoryStudentStore keeps free and hand-made codes apart", () => {
    const store = new MemoryStudentStore();
    store.add(TOKEN, { origin: "free" });
    store.add(HAND_TOKEN);
    assert.deepEqual([store.codesOf("free"), store.codesOf("admin")], [[TOKEN], [HAND_TOKEN]]);
  });
});
