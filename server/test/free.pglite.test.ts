import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import type { Db } from "../lib/db.js";
import { hashAddress } from "../lib/free-config.js";
import { handleFreeCode } from "../lib/free-code.js";
import { handleMe } from "../lib/me.js";
import { StudentAdmin, splitStatements } from "../lib/students-admin.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { claimFromStamps, PgStudentStore } from "../lib/students.js";
import { captureLogs, deps, reply } from "./helpers.js";

// Runs the real SQL of free codes (migration 005, the address limiter, the spending reserve and settle, the lookup join, the admin
// queries) on PGlite: Postgres compiled to WebAssembly, inside this process. No server, no Docker. Meant for GitHub CI (CI=true); on a
// laptop it is skipped unless PT_PGLITE=1. It proves the SQL gives the same answers as the in-memory store the other tests use.
// PGlite runs one connection, so queries are serialised: this file proves SQL correctness, NOT concurrency. Contention against the
// real database is in test/db.integration.test.ts (off unless asked for).
const enabled = process.env.CI === "true" || process.env.PT_PGLITE === "1";
const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");
const MONTH = "2026-11-01";
const NEXT_MONTH = "2026-12-01";
const SALT = "a-long-random-test-salt-0123456789abcdef";
const T0 = Date.UTC(2026, 10, 14, 18, 0, 0);
const at = (hours: number) => new Date(T0 + hours * 3600 * 1000);

describe("free codes: the real SQL on Postgres (PGlite)", { skip: !enabled }, () => {
  let pg: PGlite;
  let db: Db;
  let store: PgStudentStore;
  let admin: StudentAdmin;
  let seq = 0;
  const files = () => readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
  const apply = async (names: string[]) => {
    for (const file of names) for (const statement of splitStatements(readFileSync(join(MIGRATIONS, file), "utf8"))) await db.query(statement);
  };
  const newHash = () => `hash-${(seq += 1)}`;
  const newCode = () => {
    seq += 1;
    return `FREE${String(seq).padStart(4, "0")}`;
  };
  const one = async (sql: string, params: unknown[] = []) => (await db.query(sql, params))[0];

  before(async () => {
    pg = new PGlite();
    db = { query: async (text, params) => (await pg.query(text, params as unknown[] | undefined)).rows as Record<string, unknown>[] };
    store = new PgStudentStore(db);
    admin = new StudentAdmin(db);
    // The migrations before this change, then a code that already exists, then 005: an old code must come out as 'admin'.
    await apply(files().filter((f) => !f.startsWith("005")));
    await db.query("insert into students (code) values ('OLDCODE1')");
    await apply(files());
  });

  it("migration 005 leaves every existing code as 'admin', is safe to run twice, and the origin check refuses anything else", async () => {
    assert.equal((await one("select origin from students where code = 'OLDCODE1'"))?.origin, "admin");
    await apply(files());
    await apply(files());
    await assert.rejects(() => db.query("insert into students (code, origin) values ('BADORIGIN', 'wild')"), /students_origin_known|check/i);
    const tables = (await db.query("select table_name from information_schema.tables where table_schema = 'public'")).map((r) => String(r.table_name));
    for (const t of ["free_spend_months", "free_code_ip_limits"]) assert.ok(tables.includes(t), `${t} exists`);
  });

  it("makes free students with origin free and live voice off; an existing code is reported, not overwritten", async () => {
    const code = newCode();
    assert.equal(await store.createFreeStudent(code, 28_800), true);
    assert.equal(await store.createFreeStudent(code, 28_800), false, "the same code twice");
    const found = await store.lookup(code, MONTH);
    assert.deepEqual([found?.origin, found?.planLive, found?.capSeconds, found?.freeSpentMicros], ["free", false, 28_800, 0]);
    const old = await store.lookup("OLDCODE1", MONTH);
    assert.deepEqual([old?.origin, old?.freeSpentMicros], ["admin", null]);
  });

  it("the address limiter gives the same answer as the in-memory rule, event by event, including when to try again", async () => {
    const hash = newHash();
    let stamps: number[] = [];
    // t0, t0+1h, t0+2h allowed; then refused at +3h and +23.9h; t0 ages out at +24h; the next two are refused until +25h and +26h age out.
    for (const hours of [0, 1, 2, 3, 23.9, 24.01, 24.5, 25.1, 25.2, 26.5]) {
      const expected = claimFromStamps(stamps, at(hours).getTime(), 3);
      stamps = expected.stamps;
      const real = await store.claimFreeCodeSlot(hash, at(hours), 3);
      assert.deepEqual(real, expected.claim, `claim at +${hours} h`);
    }
  });

  it("a refused claim writes nothing", async () => {
    const hash = newHash();
    for (const h of [0, 0.1, 0.2]) assert.equal((await store.claimFreeCodeSlot(hash, at(h), 3)).allowed, true);
    const before = await one("select stamps, updated_at from free_code_ip_limits where ip_hash = $1", [hash]);
    assert.equal((await store.claimFreeCodeSlot(hash, at(1), 3)).allowed, false);
    assert.deepEqual(await one("select stamps, updated_at from free_code_ip_limits where ip_hash = $1", [hash]), before);
  });

  it("twenty claims queued at once let exactly the limit through (PGlite serialises them; real contention is in the integration test)", async () => {
    const hash = newHash();
    const results = await Promise.all(Array.from({ length: 20 }, (_, i) => store.claimFreeCodeSlot(hash, at(i / 1000), 3)));
    assert.equal(results.filter((r) => r.allowed).length, 3);
    const row = await one("select array_length(stamps, 1) as n from free_code_ip_limits where ip_hash = $1", [hash]);
    assert.equal(Number(row?.n), 3);
  });

  it("releases one claimed slot, and purges rows nobody touched since a time", async () => {
    const hash = newHash();
    await store.claimFreeCodeSlot(hash, at(0), 3);
    await store.claimFreeCodeSlot(hash, at(1), 3);
    await store.releaseFreeCodeSlot(hash, at(1));
    assert.equal(Number((await one("select array_length(stamps, 1) as n from free_code_ip_limits where ip_hash = $1", [hash]))?.n), 1);
    const old = newHash();
    await store.claimFreeCodeSlot(old, at(-100), 3);
    const purged = await store.purgeStaleFreeCodeSlots(at(-50));
    assert.ok(purged >= 1);
    assert.equal(await one("select 1 as x from free_code_ip_limits where ip_hash = $1", [old]), undefined);
    assert.ok(await one("select 1 as x from free_code_ip_limits where ip_hash = $1", [hash]), "a recent row stays");
  });

  it("reserve and settle give the same totals as the in-memory store, month by month", async () => {
    const memory = new MemoryStudentStore();
    const month = "2031-03-01";
    const ceiling = 1000;
    // reserve 400, reserve 400, refused (1200 > 1000), settle -394 (the first call cost 6), reserve 500 fits (806 + 500 > 1000? no: 6 + 400 + 500 = 906), then exactly to the ceiling.
    const steps: ({ reserve: number } | { settle: number; eleven?: number })[] = [
      { reserve: 400 }, { reserve: 400 }, { reserve: 400 }, { settle: -394 }, { reserve: 500 }, { reserve: 94 }, { reserve: 1 }, { settle: 0, eleven: 120 }, { settle: -2000 },
    ];
    for (const step of steps) {
      if ("reserve" in step) {
        const real = await store.reserveFreeSpend(month, step.reserve, ceiling);
        const mem = await memory.reserveFreeSpend(month, step.reserve, ceiling);
        assert.equal(real, mem, `reserve ${step.reserve}`);
      } else {
        const real = await store.settleFreeSpend(month, step.settle, step.eleven ?? 0);
        const mem = await memory.settleFreeSpend(month, step.settle, step.eleven ?? 0);
        assert.equal(real, mem, `settle ${step.settle}`);
      }
      assert.equal(await store.freeSpentMicros(month), memory.freeMonth(month).micros);
    }
    const row = await one("select spent_micros, eleven_chars, calls from free_spend_months where month = $1::date", [month]);
    assert.deepEqual([Number(row?.spent_micros), Number(row?.eleven_chars), Number(row?.calls)], [0, 120, memory.freeMonth(month).calls], "a settle can never take the total below zero");
  });

  it("the first reservation of a month obeys the ceiling too, and a refused one creates no row", async () => {
    const month = "2031-04-01";
    assert.equal(await store.reserveFreeSpend(month, 1001, 1000), null);
    assert.equal(await one("select 1 as x from free_spend_months where month = $1::date", [month]), undefined);
    assert.equal(await store.reserveFreeSpend(month, 1000, 1000), 1000, "exactly the ceiling is allowed");
    assert.equal(await store.reserveFreeSpend(month, 1, 1000), null);
    assert.equal(await store.reserveFreeSpend(month, 1, 0), null, "a ceiling of 0 closes it");
  });

  it("the lookup reads the month's free total in the same query; each month has its own total; hand-made codes see null", async () => {
    const code = newCode();
    await store.createFreeStudent(code, 28_800);
    await store.reserveFreeSpend(MONTH, 7_000_000, 50_000_000);
    await store.settleFreeSpend(MONTH, -1_000_000, 0);
    assert.equal((await store.lookup(code, MONTH))?.freeSpentMicros, 6_000_000, "7,000,000 reserved, 1,000,000 given back");
    assert.equal((await store.lookup(code, NEXT_MONTH))?.freeSpentMicros, 0, "a new month starts at zero");
    assert.equal((await store.lookup("OLDCODE1", MONTH))?.freeSpentMicros, null);
  });

  it("the admin queries separate the two kinds and report the stored total", async () => {
    const code = newCode();
    await store.createFreeStudent(code, 28_800);
    const free = await admin.list(MONTH, "free");
    const hand = await admin.list(MONTH, "admin");
    assert.ok(free.some((s) => s.code === code && s.origin === "free"));
    assert.ok(!hand.some((s) => s.code === code));
    assert.ok(hand.some((s) => s.code === "OLDCODE1" && s.origin === "admin"));
    assert.ok((await admin.list(MONTH)).length >= free.length + hand.length);
    assert.equal(await admin.setLive(code, true), "free");
    assert.equal(await admin.setLive("OLDCODE1", true), "ok");
    assert.equal(await admin.setLive("NOSUCHCD", true), "missing");
    await admin.setFreeSpend("2031-05-01", 12_345);
    const status = await admin.freeStatus("2031-05-01");
    assert.equal(status.spentMicros, 12_345);
    assert.ok(status.codes >= 1);
    assert.equal(await admin.setFreeSpend("2031-05-01", 0), 0);
  });

  it("the whole of POST /api/free-code and the sign-in that follows, on real SQL", async () => {
    const logs = captureLogs();
    try {
      const d = deps({ OPENAI_API_KEY: "sk-test", FREE_CODE_IP_SALT: SALT }, undefined, { store, now: () => at(0) });
      const request = () => new Request("https://example.test/api/free-code", { method: "POST", headers: { "x-real-ip": "203.0.113.200" }, body: "{}" });
      const codes: string[] = [];
      for (let i = 0; i < 3; i += 1) {
        const r = await reply(await handleFreeCode(request(), d));
        assert.equal(r.status, 200);
        codes.push(String(r.json.code));
      }
      assert.equal((await handleFreeCode(request(), d)).status, 429);
      const hash = hashAddress("203.0.113.200", SALT);
      assert.equal(Number((await one("select array_length(stamps, 1) as n from free_code_ip_limits where ip_hash = $1", [hash]))?.n), 3);
      const info = await reply(await handleMe(new Request("https://example.test/api/me", { headers: { authorization: `Bearer ${codes[0]}` } }), d));
      assert.equal(info.status, 200);
      assert.deepEqual(info.json.free, { full: false });
      assert.ok(!logs.raw.join("\n").includes(String(codes[0])), "the code is not logged");
    } finally {
      logs.restore();
    }
  });
});
