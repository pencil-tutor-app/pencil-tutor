import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import type { Db } from "../lib/db.js";
import { NOTICE_VERSION } from "../lib/record/notice.js";
import { RecordAdmin } from "../lib/record/admin.js";
import { PgRecordStore } from "../lib/record/store.js";
import { splitStatements } from "../lib/students-admin.js";

// Runs the real SQL of the opt-in student record (migration 004, lib/record/store.ts, lib/record/admin.ts) on PGlite: Postgres
// compiled to WebAssembly, inside this process. No server, no Docker. Meant for GitHub CI (CI=true); on a laptop it is skipped
// unless PT_PGLITE=1. The production Neon database is never touched. It cannot show Neon timing or real concurrency.
const enabled = process.env.CI === "true" || process.env.PT_PGLITE === "1";
const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");

describe("student record SQL on Postgres (PGlite)", { skip: !enabled }, () => {
  let pg: PGlite;
  let db: Db;
  let store: PgRecordStore;
  let admin: RecordAdmin;
  let seq = 0;

  const applyMigrations = async () => {
    for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
      for (const statement of splitStatements(readFileSync(join(MIGRATIONS, file), "utf8"))) await db.query(statement);
    }
  };
  async function student(): Promise<{ id: string; code: string }> {
    seq += 1;
    const code = `TESTCODE${seq}`;
    const rows = await db.query("insert into students (code) values ($1) returning id", [code]);
    return { id: String(rows[0]?.id), code };
  }
  const count = async (table: string, id: string) => Number((await db.query(`select count(*) as n from ${table} where student_id = $1::bigint`, [id]))[0]?.n);
  const look = (id: string, args: Partial<{ sessionId: string; problemId: string; interrupt: { line: number; revision: number } | null; wantNotes: boolean }> = {}) =>
    store.recordLook(id, NOTICE_VERSION, { sessionId: "s1", problemId: "u3-04", interrupt: null, wantNotes: false, ...args });
  const agree = (id: string) => store.grant(id, { givenBy: "parent_guardian", via: "app", noticeVersion: NOTICE_VERSION, noticeHash: "h" });

  before(async () => {
    pg = new PGlite();
    db = { query: async (text, params) => (await pg.query(text, params as unknown[] | undefined)).rows as Record<string, unknown>[] };
    store = new PgRecordStore(db);
    admin = new RecordAdmin(db);
    await applyMigrations();
  });

  it("migrations are safe to run twice", async () => {
    await applyMigrations();
    const tables = (await db.query("select table_name from information_schema.tables where table_schema = 'public'")).map((r) => String(r.table_name));
    for (const t of ["consent_events", "human_note", "attempt", "hint_event"]) assert.ok(tables.includes(t), `${t} exists`);
  });

  it("records nothing, and returns no notes, for a student who never agreed", async () => {
    const s = await student();
    const out = await look(s.id, { interrupt: { line: 2, revision: 1 }, wantNotes: true });
    assert.deepEqual(out, { consented: false, notes: [] });
    assert.equal(await store.recordQuestion(s.id, NOTICE_VERSION, { sessionId: "s1", problemId: "u3-04" }), false);
    assert.deepEqual([await count("attempt", s.id), await count("hint_event", s.id)], [0, 0]);
  });

  it("records looks, hint events and questions after agreement; a retry adds no second hint row", async () => {
    const s = await student();
    await agree(s.id);
    assert.equal((await look(s.id)).consented, true);
    await look(s.id);
    await look(s.id, { interrupt: { line: 2, revision: 5 } });
    await look(s.id, { interrupt: { line: 2, revision: 5 } }); // the same request sent again
    await store.recordQuestion(s.id, NOTICE_VERSION, { sessionId: "s1", problemId: "u3-04" });
    await look(s.id, { sessionId: "s2", problemId: "u3-01" });
    const status = await store.status(s.id);
    assert.equal(status.recent.length, 2);
    assert.deepEqual(status.recent.find((r) => r.problemId === "u3-04"), { problemId: "u3-04", looks: 4, asks: 1, interrupts: 1, lastAt: status.recent.find((r) => r.problemId === "u3-04")!.lastAt });
    assert.equal(status.recent[0]?.problemId, "u3-01", "newest first");
    assert.equal(await count("hint_event", s.id), 1);
  });

  it("an agreement to an older text records nothing", async () => {
    const s = await student();
    await store.grant(s.id, { givenBy: "adult_student", via: "admin", noticeVersion: "2026-01-01.1", noticeHash: "old", evidenceOn: "2026-01-01" });
    assert.equal((await look(s.id)).consented, false);
    assert.equal(await count("attempt", s.id), 0);
  });

  it("hands back at most three notes, pinned first and then newest, only for an interrupt that asks", async () => {
    const s = await student();
    await agree(s.id);
    assert.ok(await admin.addNote(s.id, "old note", "2026-10-01", false));
    assert.ok(await admin.addNote(s.id, "pinned note", "2026-09-01", true));
    assert.ok(await admin.addNote(s.id, "newest note", "2026-11-10", false));
    assert.ok(await admin.addNote(s.id, "middle note", "2026-11-01", false));
    const none = await look(s.id, { interrupt: { line: 1, revision: 1 }, wantNotes: false });
    assert.deepEqual(none.notes, []);
    const got = await look(s.id, { interrupt: { line: 1, revision: 2 }, wantNotes: true });
    assert.deepEqual(got.notes.map((n) => n.body), ["pinned note", "newest note", "middle note"]);
    assert.equal(got.notes[1]?.sessionOn, "2026-11-10");
  });

  it("withdrawal stops recording and notes at once, keeps what is stored, and is not repeated", async () => {
    const s = await student();
    await agree(s.id);
    await admin.addNote(s.id, "a note", "2026-11-10", false);
    await look(s.id, { interrupt: { line: 2, revision: 1 } });
    const first = await store.withdraw(s.id, "app", NOTICE_VERSION, false);
    assert.equal(first.withdrawn, 1);
    const after = await look(s.id, { interrupt: { line: 2, revision: 2 }, wantNotes: true });
    assert.deepEqual(after, { consented: false, notes: [] });
    assert.deepEqual([await count("attempt", s.id), await count("hint_event", s.id), await count("human_note", s.id)], [1, 1, 1]);
    assert.equal((await store.withdraw(s.id, "app", NOTICE_VERSION, false)).withdrawn, 0);
    assert.equal(await count("consent_events", s.id), 2);
    assert.equal((await store.status(s.id)).consent?.granted, false);
  });

  it("withdraw with erase, and erase alone, delete the record and report counts; the consent log stays", async () => {
    const s = await student();
    await agree(s.id);
    await admin.addNote(s.id, "a note", "2026-11-10", false);
    await look(s.id, { interrupt: { line: 2, revision: 1 } });
    const done = await store.withdraw(s.id, "app", NOTICE_VERSION, true);
    assert.deepEqual(done, { withdrawn: 1, hints: 1, attempts: 1, notes: 1 });
    assert.deepEqual([await count("attempt", s.id), await count("hint_event", s.id), await count("human_note", s.id)], [0, 0, 0]);
    assert.equal(await count("consent_events", s.id), 2);

    const t = await student();
    await agree(t.id);
    await look(t.id);
    assert.deepEqual(await store.erase(t.id), { withdrawn: 0, hints: 0, attempts: 1, notes: 0 });
    assert.equal((await look(t.id)).consented, true, "erase alone leaves the agreement in place");
  });

  it("admin: a note is refused without agreement; export holds the record and never the code; the log can go too", async () => {
    const s = await student();
    assert.equal(await admin.addNote(s.id, "no consent yet", "2026-11-10", false), null);
    await admin.recordConsent(s.id, "adult_student", "2026-11-12");
    const consent = await admin.consentOf(s.id);
    assert.deepEqual([consent?.granted, consent?.givenBy, consent?.recordedVia, consent?.evidenceOn, consent?.noticeVersion], [true, "adult_student", "admin", "2026-11-12", NOTICE_VERSION]);
    const noteId = await admin.addNote(s.id, "keeps going after a wrong answer", "2026-11-12", true);
    assert.ok(noteId);
    await look(s.id, { interrupt: { line: 2, revision: 1 } });
    const dump = JSON.stringify(await admin.exportAll(s.id, s.code));
    assert.ok(!dump.includes(s.code), "the code is never in the export");
    const parsed = JSON.parse(dump) as { notes: unknown[]; attempts: unknown[]; hint_events: unknown[]; consent_events: unknown[]; student_log_id: string };
    assert.deepEqual([parsed.notes.length, parsed.attempts.length, parsed.hint_events.length, parsed.consent_events.length], [1, 1, 1, 1]);
    assert.equal(parsed.student_log_id.length, 8);
    assert.equal(await admin.deleteNote(s.id, noteId!), true);
    assert.equal((await admin.withdraw(s.id, true)).withdrawn, 1);
    assert.equal(await admin.deleteConsentLog(s.id), 2);
    assert.equal(await admin.consentOf(s.id), null);
  });

  it("admin: lists memory on or off, and finds codes unused for a while", async () => {
    const s = await student();
    await admin.recordConsent(s.id, "parent_guardian", null);
    await look(s.id);
    assert.equal((await admin.list()).find((r) => r.code === s.code)?.on, true);
    assert.equal((await admin.inactive(12)).some((r) => r.id === s.id), false, "just made, so not inactive");
    await db.query("update students set created_at = now() - interval '14 months' where id = $1::bigint", [s.id]);
    assert.equal((await admin.inactive(12)).some((r) => r.id === s.id), true);
    await db.query("insert into usage_months (student_id, month, last_activity_at) values ($1::bigint, '2026-11-01', now())", [s.id]);
    assert.equal((await admin.inactive(12)).some((r) => r.id === s.id), false, "recent activity keeps it");
  });

  it("stays quick on a student with thousands of rows (PGlite timing; not a Neon number)", async () => {
    const s = await student();
    await agree(s.id);
    await db.query(
      `insert into attempt (student_id, session_id, problem_id, looks) select $1::bigint, 'bulk-' || g, 'u3-0' || (g % 9), 1 from generate_series(1, 3000) g`,
      [s.id],
    );
    for (let i = 0; i < 12; i += 1) await admin.addNote(s.id, `note ${i}`, "2026-11-01", i === 0);
    const timed = async (run: () => Promise<unknown>) => {
      const started = performance.now();
      await run();
      return performance.now() - started;
    };
    const writeMs = await timed(() => look(s.id, { sessionId: "timed", interrupt: { line: 1, revision: 1 }, wantNotes: true }));
    const statusMs = await timed(() => store.status(s.id));
    console.log(`record SQL on PGlite with 3000 attempts: look+notes ${writeMs.toFixed(1)} ms, status ${statusMs.toFixed(1)} ms`);
    assert.ok(writeMs < 500 && statusMs < 500, "under the 500 ms house rule even on WebAssembly");
  });
});
