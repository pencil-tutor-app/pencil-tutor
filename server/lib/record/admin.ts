import type { Db } from "../db.js";
import { codeHash } from "../students.js";
import { NOTICE_VERSION, noticeHash } from "./notice.js";
import { PgRecordStore, type Deleted, type GivenBy } from "./store.js";

// What Edward's local tool (scripts/codes) does with the student record: record a consent from a signed form, write his notes,
// export everything stored about a code, delete it. Never imported by the server's request path. Output is counts, dates and log
// ids; a code is looked up here but never printed.

const toInt = (v: unknown): number => Number(v ?? 0);
const toIso = (v: unknown): string => (v instanceof Date ? v : new Date(String(v))).toISOString();

export type ConsentView = { granted: boolean; givenBy: string | null; recordedVia: string; noticeVersion: string; evidenceOn: string | null; at: string };
export type NoteView = { id: string; sessionOn: string; body: string; pinned: boolean; createdAt: string };

export class RecordAdmin {
  private readonly store: PgRecordStore;
  constructor(private readonly db: Db) {
    this.store = new PgRecordStore(db);
  }

  // The student's id for a code, or null.
  async idOf(code: string): Promise<string | null> {
    const rows = await this.db.query("select id from students where code = $1", [code]);
    return rows[0]?.id === undefined ? null : String(rows[0].id);
  }

  async consentOf(studentId: string): Promise<ConsentView | null> {
    const rows = await this.db.query(
      `select granted, given_by, recorded_via, notice_version, to_char(evidence_on, 'YYYY-MM-DD') as evidence_on, at
       from consent_events where student_id = $1::bigint order by id desc limit 1`,
      [studentId],
    );
    const r = rows[0];
    if (!r) return null;
    return {
      granted: Boolean(r.granted),
      givenBy: r.given_by == null ? null : String(r.given_by),
      recordedVia: String(r.recorded_via),
      noticeVersion: String(r.notice_version),
      evidenceOn: r.evidence_on == null ? null : String(r.evidence_on),
      at: toIso(r.at),
    };
  }

  // Memory on or off for every code, by log id. No counts.
  async list(): Promise<{ hash: string; code: string; on: boolean; version: string | null }[]> {
    const rows = await this.db.query(
      `select s.code, c.granted, c.notice_version
       from students s
       left join lateral (select granted, notice_version from consent_events where student_id = s.id order by id desc limit 1) c on true
       order by s.id`,
    );
    return rows.map((r) => ({
      code: String(r.code),
      hash: codeHash(String(r.code)),
      on: Boolean(r.granted) && String(r.notice_version) === NOTICE_VERSION,
      version: r.notice_version == null ? null : String(r.notice_version),
    }));
  }

  // A consent recorded from a signed paper form. `formDate` is the date on the form (YYYY-MM-DD); no name is stored.
  async recordConsent(studentId: string, givenBy: GivenBy, formDate: string | null): Promise<void> {
    await this.store.grant(studentId, { givenBy, via: "admin", noticeVersion: NOTICE_VERSION, noticeHash: noticeHash(), evidenceOn: formDate });
  }

  // Withdraws (if there is a grant) and, if asked, deletes the record, in one statement. Safe to run again.
  withdraw(studentId: string, erase: boolean): Promise<Deleted> {
    return this.store.withdraw(studentId, "admin", NOTICE_VERSION, erase);
  }

  // Adds a note. Refused (null) when the code has no grant: nothing is remembered without consent.
  async addNote(studentId: string, body: string, sessionOn: string, pinned: boolean): Promise<string | null> {
    const rows = await this.db.query(
      `insert into human_note (student_id, session_on, body, pinned)
       select $1::bigint, $3::date, $2::text, $4::boolean
       where coalesce((select granted from consent_events where student_id = $1::bigint order by id desc limit 1), false)
       returning id`,
      [studentId, body, sessionOn, pinned],
    );
    return rows[0] ? String(rows[0].id) : null;
  }

  async listNotes(studentId: string): Promise<NoteView[]> {
    const rows = await this.db.query(
      `select id, to_char(session_on, 'YYYY-MM-DD') as session_on, body, pinned, created_at
       from human_note where student_id = $1::bigint order by pinned desc, session_on desc, id desc`,
      [studentId],
    );
    return rows.map((r) => ({ id: String(r.id), sessionOn: String(r.session_on), body: String(r.body), pinned: Boolean(r.pinned), createdAt: toIso(r.created_at) }));
  }

  async deleteNote(studentId: string, noteId: string): Promise<boolean> {
    const rows = await this.db.query("delete from human_note where id = $1::bigint and student_id = $2::bigint returning id", [noteId, studentId]);
    return rows.length > 0;
  }

  // Everything stored about this student (PIPA s. 23), keyed by the log id, never by the code.
  async exportAll(studentId: string, code: string): Promise<Record<string, unknown>> {
    const [consent, notes, attempts, hints] = await Promise.all([
      this.db.query(
        `select granted, given_by, recorded_via, notice_version, notice_hash, to_char(evidence_on, 'YYYY-MM-DD') as evidence_on, at
         from consent_events where student_id = $1::bigint order by id`,
        [studentId],
      ),
      this.listNotes(studentId),
      this.db.query("select id, session_id, problem_id, looks, asks, first_at, last_at from attempt where student_id = $1::bigint order by id", [studentId]),
      this.db.query("select attempt_id, line, drawing_revision, at from hint_event where student_id = $1::bigint order by id", [studentId]),
    ]);
    return {
      exported_at: new Date().toISOString(),
      student_log_id: codeHash(code),
      notice_version_now: NOTICE_VERSION,
      consent_events: consent.map((r) => ({
        granted: Boolean(r.granted), given_by: r.given_by ?? null, recorded_via: r.recorded_via, notice_version: r.notice_version,
        notice_hash: r.notice_hash ?? null, evidence_on: r.evidence_on ?? null, at: toIso(r.at),
      })),
      notes: notes.map((n) => ({ id: n.id, session_on: n.sessionOn, body: n.body, pinned: n.pinned, created_at: n.createdAt })),
      attempts: attempts.map((r) => ({
        id: String(r.id), session_id: r.session_id, problem_id: r.problem_id, looks: toInt(r.looks), asks: toInt(r.asks),
        first_at: toIso(r.first_at), last_at: toIso(r.last_at),
      })),
      hint_events: hints.map((r) => ({ attempt_id: String(r.attempt_id), line: toInt(r.line), drawing_revision: toInt(r.drawing_revision), at: toIso(r.at) })),
      note: "The server holds no hint text, pictures, recordings or names. 'Looks' and 'interrupts' count what the server decided, not what was shown.",
    };
  }

  // Also removes the consent log (the audit trail that an erase otherwise keeps). Run after withdraw().
  async deleteConsentLog(studentId: string): Promise<number> {
    const rows = await this.db.query("delete from consent_events where student_id = $1::bigint returning id", [studentId]);
    return rows.length;
  }

  // Codes with record data whose last activity is older than `months` (the last counted activity, else when the code was made).
  async inactive(months: number): Promise<{ id: string; hash: string; lastUsed: string }[]> {
    const rows = await this.db.query(
      `select s.id, s.code, greatest(s.created_at, coalesce((select max(u.last_activity_at) from usage_months u where u.student_id = s.id), s.created_at)) as last_used
       from students s
       where (exists (select 1 from attempt a where a.student_id = s.id)
           or exists (select 1 from human_note n where n.student_id = s.id)
           or exists (select 1 from consent_events e where e.student_id = s.id))
         and greatest(s.created_at, coalesce((select max(u.last_activity_at) from usage_months u where u.student_id = s.id), s.created_at))
             < now() - make_interval(months => $1::int)
       order by s.id`,
      [months],
    );
    return rows.map((r) => ({ id: String(r.id), hash: codeHash(String(r.code)), lastUsed: toIso(r.last_used) }));
  }
}
