import type { Db } from "../db.js";

// The opt-in student record. All SQL for the request path is here, through Db.query only (raw SQL, numbered placeholders).
// Nothing is written for a student unless the latest consent_events row is a grant for the current notice version; the
// check is inside each writing statement, so a withdrawal that commits first wins.

export type GivenBy = "parent_guardian" | "adult_student";
export type RecordedVia = "app" | "admin";

export type Consent = {
  granted: boolean;
  givenBy: GivenBy | null;
  recordedVia: RecordedVia;
  noticeVersion: string;
  at: string;
};

export type Note = { id: string; sessionOn: string; body: string; pinned: boolean };
export type RecentAttempt = { problemId: string; looks: number; asks: number; interrupts: number; lastAt: string };
export type Status = { consent: Consent | null; notes: number; recent: RecentAttempt[] };
export type Deleted = { withdrawn: number; hints: number; attempts: number; notes: number };

export type LookArgs = {
  sessionId: string;
  problemId: string;
  // Set when the server decided to interrupt on this look.
  interrupt: { line: number; revision: number } | null;
  // Ask for Edward's notes back (only an interrupt that may be reworded needs them).
  wantNotes: boolean;
};
export type LookResult = { consented: boolean; notes: Note[] };

export interface RecordStore {
  readonly kind: "postgres" | "stub";
  // Records one look (and its hint event) for a student who has consented, and returns their notes when asked.
  recordLook(studentId: string, noticeVersion: string, args: LookArgs): Promise<LookResult>;
  // Counts one spoken question. Returns whether the student had consented.
  recordQuestion(studentId: string, noticeVersion: string, args: { sessionId: string; problemId: string }): Promise<boolean>;
  status(studentId: string): Promise<Status>;
  grant(studentId: string, args: { givenBy: GivenBy; via: RecordedVia; noticeVersion: string; noticeHash: string; evidenceOn?: string | null }): Promise<void>;
  // Records a withdrawal (when there is a grant to withdraw) and, if asked, deletes the student's record. One statement.
  withdraw(studentId: string, via: RecordedVia, noticeVersion: string, erase: boolean): Promise<Deleted>;
  // Deletes the student's record without touching consent.
  erase(studentId: string): Promise<Deleted>;
}

// The write path must never hold up a student's look: 400 ms, then the request carries on without the record.
export const WRITE_TIMEOUT_MS = 400;

const toInt = (v: unknown): number => Number(v ?? 0);
const toIso = (v: unknown): string => (v instanceof Date ? v : new Date(String(v))).toISOString();

// One statement, one round trip. `ok` is the consent check; `a` the attempt upsert; `h` the hint event (only for an interrupt);
// the final select returns whether consent held and, for an interrupt that asked for them, the top three notes (pinned first,
// then newest). `from (select 1)` keeps one row even when there are no notes. Placeholders: $1 student, $2 notice version,
// $3 session, $4 problem, $5 looks to add, $6 asks to add, $7 line (null: no interrupt), $8 revision, $9 want notes.
const RECORD_SQL = `
with c as (
  select granted, notice_version from consent_events where student_id = $1::bigint order by id desc limit 1
), ok as (
  select 1 as one from c where c.granted and c.notice_version = $2::text
), a as (
  insert into attempt as t (student_id, session_id, problem_id, looks, asks)
  select $1::bigint, $3::text, $4::text, $5::int, $6::int from ok
  on conflict (student_id, session_id, problem_id) do update
    set looks = t.looks + $5::int, asks = t.asks + $6::int, last_at = now()
  returning id
), h as (
  insert into hint_event (student_id, attempt_id, line, drawing_revision)
  select $1::bigint, a.id, $7::int, $8::int from a where $7::int is not null
  on conflict (attempt_id, drawing_revision, line) do nothing
  returning id
)
select (select count(*) from ok) as consented, n.id, to_char(n.session_on, 'YYYY-MM-DD') as session_on, n.body, n.pinned
from (select 1) x
left join lateral (
  select id, session_on, body, pinned from human_note
  where student_id = $1::bigint and $9::boolean and exists (select 1 from ok)
  order by pinned desc, session_on desc, id desc limit 3
) n on true`;

const LATEST_CONSENT_SQL = `
select granted, given_by, recorded_via, notice_version, at from consent_events where student_id = $1::bigint order by id desc limit 1`;

const NOTES_COUNT_SQL = `select count(*) as n from human_note where student_id = $1::bigint`;

const RECENT_SQL = `
select a.problem_id, a.looks, a.asks, a.last_at, (select count(*) from hint_event h where h.attempt_id = a.id) as interrupts
from attempt a where a.student_id = $1::bigint order by a.last_at desc, a.id desc limit 10`;

const GRANT_SQL = `
insert into consent_events (student_id, granted, given_by, recorded_via, notice_version, notice_hash, evidence_on)
values ($1::bigint, true, $2::text, $3::text, $4::text, $5::text, $6::date) returning id`;

// Withdrawal and erase in one statement. $2 via, $3 notice version, $4 write a withdrawal row (only if the latest row is a
// grant), $5 delete the record. Returns what it did.
const WITHDRAW_ERASE_SQL = `
with latest as (
  select granted from consent_events where student_id = $1::bigint order by id desc limit 1
), w as (
  insert into consent_events (student_id, granted, given_by, recorded_via, notice_version)
  select $1::bigint, false, null, $2::text, $3::text where $4::boolean and coalesce((select granted from latest), false)
  returning id
), dh as (
  delete from hint_event where student_id = $1::bigint and $5::boolean returning id
), da as (
  delete from attempt where student_id = $1::bigint and $5::boolean returning id
), dn as (
  delete from human_note where student_id = $1::bigint and $5::boolean returning id
)
select (select count(*) from w) as withdrawn, (select count(*) from dh) as hints, (select count(*) from da) as attempts, (select count(*) from dn) as notes`;

export class PgRecordStore implements RecordStore {
  readonly kind = "postgres" as const;
  constructor(private readonly db: Db) {}

  private async record(studentId: string, noticeVersion: string, args: LookArgs & { looks: number; asks: number }): Promise<LookResult> {
    const rows = await this.db.query(
      RECORD_SQL,
      [
        studentId, noticeVersion, args.sessionId, args.problemId, args.looks, args.asks,
        args.interrupt?.line ?? null, args.interrupt?.revision ?? null, args.wantNotes,
      ],
      { timeoutMs: WRITE_TIMEOUT_MS },
    );
    const consented = toInt(rows[0]?.consented) > 0;
    const notes: Note[] = consented
      ? rows.flatMap((r) => (r.id == null ? [] : [{ id: String(r.id), sessionOn: String(r.session_on), body: String(r.body), pinned: Boolean(r.pinned) }]))
      : [];
    return { consented, notes };
  }

  recordLook(studentId: string, noticeVersion: string, args: LookArgs): Promise<LookResult> {
    return this.record(studentId, noticeVersion, { ...args, looks: 1, asks: 0 });
  }

  async recordQuestion(studentId: string, noticeVersion: string, args: { sessionId: string; problemId: string }): Promise<boolean> {
    const result = await this.record(studentId, noticeVersion, { ...args, interrupt: null, wantNotes: false, looks: 0, asks: 1 });
    return result.consented;
  }

  async status(studentId: string): Promise<Status> {
    const [consentRows, noteRows, recentRows] = await Promise.all([
      this.db.query(LATEST_CONSENT_SQL, [studentId]),
      this.db.query(NOTES_COUNT_SQL, [studentId]),
      this.db.query(RECENT_SQL, [studentId]),
    ]);
    const c = consentRows[0];
    return {
      consent: c
        ? {
            granted: Boolean(c.granted),
            givenBy: c.given_by == null ? null : (String(c.given_by) as GivenBy),
            recordedVia: String(c.recorded_via) as RecordedVia,
            noticeVersion: String(c.notice_version),
            at: toIso(c.at),
          }
        : null,
      notes: toInt(noteRows[0]?.n),
      recent: recentRows.map((r) => ({
        problemId: String(r.problem_id),
        looks: toInt(r.looks),
        asks: toInt(r.asks),
        interrupts: toInt(r.interrupts),
        lastAt: toIso(r.last_at),
      })),
    };
  }

  async grant(studentId: string, args: { givenBy: GivenBy; via: RecordedVia; noticeVersion: string; noticeHash: string; evidenceOn?: string | null }): Promise<void> {
    await this.db.query(GRANT_SQL, [studentId, args.givenBy, args.via, args.noticeVersion, args.noticeHash, args.evidenceOn ?? null]);
  }

  private async withdrawErase(studentId: string, via: RecordedVia, noticeVersion: string, withdraw: boolean, erase: boolean): Promise<Deleted> {
    const rows = await this.db.query(WITHDRAW_ERASE_SQL, [studentId, via, noticeVersion, withdraw, erase]);
    const r = rows[0] ?? {};
    return { withdrawn: toInt(r.withdrawn), hints: toInt(r.hints), attempts: toInt(r.attempts), notes: toInt(r.notes) };
  }

  withdraw(studentId: string, via: RecordedVia, noticeVersion: string, erase: boolean): Promise<Deleted> {
    return this.withdrawErase(studentId, via, noticeVersion, true, erase);
  }

  erase(studentId: string): Promise<Deleted> {
    return this.withdrawErase(studentId, "app", "-", false, true);
  }
}
