import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { openDb, type Db } from "../lib/db.js";
import { StudentAdmin } from "../lib/students-admin.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { isValidCode, PgStudentStore } from "../lib/students.js";

// These run the real SQL against the real Neon database, so they are OFF unless asked for: set PT_DB_INTEGRATION=1 and
// DATABASE_URL (load it exec-only, for example `vercel env run -e production -- npx tsx --test test/db.integration.test.ts`).
// They create their own random test codes in the far-future month 2030-01 and delete them afterwards. CI has no DATABASE_URL, so
// it skips them. No local Postgres is involved.
const url = process.env.DATABASE_URL;
const enabled = process.env.PT_DB_INTEGRATION === "1" && Boolean(url);

const MONTH = "2030-01-01";
const t = (seconds: number) => new Date(Date.UTC(2030, 0, 15, 12, 0, 0) + seconds * 1000);

describe("postgres store and admin", { skip: !enabled }, () => {
  let db: Db;
  let admin: StudentAdmin;
  let store: PgStudentStore;
  const created: string[] = [];
  const queryMs: number[] = [];

  async function newStudent(options: { capSeconds?: number; planLive?: boolean } = {}) {
    const { code } = await admin.create(options);
    created.push(code);
    const found = await store.lookup(code, MONTH);
    assert.ok(found, "the new code can be looked up");
    return { code, id: found.id };
  }

  before(async () => {
    const real = openDb(process.env)!;
    // Wrap the door to measure every query (the house rule is under 500 ms, aiming for 50).
    db = {
      async query(text, params) {
        const started = Date.now();
        try {
          return await real.query(text, params);
        } finally {
          queryMs.push(Date.now() - started);
        }
      },
    };
    admin = new StudentAdmin(db);
    store = new PgStudentStore(db);
    await db.query("select 1"); // wake the database so the timings below are warm
    queryMs.length = 0;
  });

  after(async () => {
    for (const code of created) await admin.remove(code);
    const slow = queryMs.filter((ms) => ms > 500);
    console.log(`db integration: ${queryMs.length} queries, median ${[...queryMs].sort((a, b) => a - b)[Math.floor(queryMs.length / 2)]} ms, max ${Math.max(...queryMs)} ms, over 500 ms: ${slow.length}`);
  });

  it("migrates, and migrating again applies nothing", async () => {
    await admin.migrate();
    assert.deepEqual(await admin.migrate(), []);
  });

  it("creates codes in the right format; an unknown code is not found", async () => {
    const { code } = await newStudent();
    assert.ok(isValidCode(code));
    assert.equal(await store.lookup("ZZZZZZZZ", MONTH), null);
  });

  it("new students default to 8 hours and the live plan off", async () => {
    const { code } = await newStudent();
    const found = await store.lookup(code, MONTH);
    assert.deepEqual([found?.capSeconds, found?.planLive, found?.disabled], [28800, false, false]);
  });

  it("counts time exactly as the in-memory rule does, event by event", async () => {
    const pg = await newStudent();
    const memory = new MemoryStudentStore();
    const memoryId = memory.add("AAAAAAAA");
    for (const offset of [0, 0, 60, 61, 200, 200, 500, 515, 10_000]) {
      const fromPg = await store.chargeActivity(pg.id, MONTH, t(offset), "look");
      const fromMemory = await memory.chargeActivity(memoryId, MONTH, t(offset), "look");
      assert.equal(fromPg.countedSeconds, fromMemory.countedSeconds, `counted seconds after an event at +${offset}s`);
      assert.equal(fromPg.coveredUntil?.getTime(), fromMemory.coveredUntil?.getTime(), `covered until after +${offset}s`);
    }
  });

  it("counts five simultaneous events at the same moment once (the upsert is atomic)", async () => {
    const { code, id } = await newStudent();
    const results = await Promise.all([1, 2, 3, 4, 5].map(() => store.chargeActivity(id, MONTH, t(0), "heartbeat")));
    const final = await store.lookup(code, MONTH);
    assert.equal(final?.usage.countedSeconds, 120);
    assert.ok(results.every((r) => r.countedSeconds <= 120));
  });

  it("keeps each month separate", async () => {
    const { code, id } = await newStudent();
    await store.chargeActivity(id, "2030-01-01", t(0), "look");
    await store.chargeActivity(id, "2030-02-01", t(0), "look");
    assert.equal((await store.lookup(code, "2030-01-01"))?.usage.countedSeconds, 120);
    assert.equal((await store.lookup(code, "2030-02-01"))?.usage.countedSeconds, 120);
    assert.equal((await store.lookup(code, "2030-03-01"))?.usage.countedSeconds, 0);
  });

  it("hands each notice to exactly one of several simultaneous claimants", async () => {
    const { id } = await newStudent();
    await store.chargeActivity(id, MONTH, t(0), "look"); // makes the month's row
    const low = await Promise.all([1, 2, 3, 4, 5].map(() => store.claimNotice(id, MONTH, "low")));
    const usedUp = await Promise.all([1, 2, 3].map(() => store.claimNotice(id, MONTH, "used_up")));
    assert.equal(low.filter(Boolean).length, 1);
    assert.equal(usedUp.filter(Boolean).length, 1);
  });

  it("adds up spoken characters, with ElevenLabs characters kept separately", async () => {
    const { id } = await newStudent();
    assert.equal(await store.addSpeech(id, MONTH, 100, "elevenlabs"), 100);
    assert.equal(await store.addSpeech(id, MONTH, 40, "openai"), 140);
    const rows = await db.query("select tts_chars, tts_chars_eleven, tts_utterances from usage_months where student_id = $1::bigint and month = $2::date", [id, MONTH]);
    assert.deepEqual([Number(rows[0]?.tts_chars), Number(rows[0]?.tts_chars_eleven), Number(rows[0]?.tts_utterances)], [140, 100, 2]);
  });

  it("top-up adds to this month's cap only, and re-arms the notices", async () => {
    const { code, id } = await newStudent({ capSeconds: 600 });
    await store.chargeActivity(id, MONTH, t(0), "look");
    await store.claimNotice(id, MONTH, "low");
    await store.claimNotice(id, MONTH, "used_up");
    await db.query("update usage_months set counted_seconds = 600 where student_id = $1::bigint and month = $2::date", [id, MONTH]);
    const after = await admin.topUp(code, MONTH, 3600);
    assert.equal(after?.bonusSeconds, 3600);
    assert.equal(after?.state, "ok");
    const found = await store.lookup(code, MONTH);
    assert.deepEqual([found?.usage.bonusSeconds, found?.usage.lowNoticed, found?.usage.usedUpNoticed], [3600, false, false]);
    assert.equal((await store.lookup(code, "2030-02-01"))?.usage.bonusSeconds, 0, "next month starts from the base cap");
    assert.equal(await admin.topUp("ZZZZZZZZ", MONTH, 60), null, "unknown code");
  });

  it("disables, enables and sets the live plan", async () => {
    const { code } = await newStudent();
    assert.equal(await admin.setDisabled(code, true), true);
    assert.equal((await store.lookup(code, MONTH))?.disabled, true);
    assert.equal(await admin.setDisabled(code, false), true);
    assert.equal((await store.lookup(code, MONTH))?.disabled, false);
    assert.equal(await admin.setLive(code, true), true);
    assert.equal((await store.lookup(code, MONTH))?.planLive, true);
    assert.equal(await admin.setDisabled("ZZZZZZZZ", true), false);
  });

  it("lists students with this month's usage and the log hash", async () => {
    const { code, id } = await newStudent();
    await store.chargeActivity(id, MONTH, t(0), "look");
    const listed = (await admin.list(MONTH)).find((s) => s.code === code);
    assert.ok(listed);
    assert.deepEqual([listed.usedSeconds, listed.remainingMinutes, listed.state, listed.planLive], [120, 478, "ok", false]);
    assert.match(listed.hash, /^[0-9a-f]{8}$/);
  });

  it("deleting a code removes its usage rows", async () => {
    const { code, id } = await newStudent();
    await store.chargeActivity(id, MONTH, t(0), "look");
    assert.equal(await admin.remove(code), true);
    created.splice(created.indexOf(code), 1);
    const rows = await db.query("select 1 from usage_months where student_id = $1::bigint", [id]);
    assert.equal(rows.length, 0);
    assert.equal(await store.lookup(code, MONTH), null);
  });

  // The timings printed above include this laptop's network to Neon, so they are only a sanity check here. The server-side
  // time (Vercel to Neon) is measured on the deployed function and logged per request as db_ms.
  it("recorded a timing for every query", () => {
    assert.ok(queryMs.length > 0);
  });
});
