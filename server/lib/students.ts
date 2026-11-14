import { createHash, randomInt } from "node:crypto";
import type { Db } from "./db.js";

// Student codes, the monthly hours cap and the rules that count time. Pure functions first (tested without a database),
// then the store interface the server uses, then its Postgres implementation. All SQL for the server path is in this file;
// the admin script's SQL is in students-admin.ts. Both reach Postgres only through lib/db.ts.
//
// No student names are stored anywhere: a student is a random code and a number.

// Eight characters from 30 symbols (no I, L, O, U, 0, 1, which look like each other or like other letters): 30^8 is about
// 6.6e11 codes, so guessing a live code is not practical. The app normalizes what a student types before sending.
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789";
export const CODE_LENGTH = 8;
const CODE_PATTERN = new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`);

export const isValidCode = (value: string): boolean => CODE_PATTERN.test(value);

export function generateCode(pick: (below: number) => number = (n) => randomInt(n)): string {
  let code = "";
  for (let i = 0; i < CODE_LENGTH; i += 1) code += CODE_ALPHABET[pick(CODE_ALPHABET.length)];
  return code;
}

// What a person types or pastes, as the canonical form: trimmed, upper case, spaces and dashes dropped.
export const normalizeCode = (typed: string): string => typed.trim().toUpperCase().replace(/[\s-]+/g, "");

// A code is an identifier, so logs carry only this short salted hash of it (8 hex characters).
export const codeHash = (code: string): string => createHash("sha256").update(`pencil-tutor:${code}`).digest("hex").slice(0, 8);

// ----- Counting time -----

// Counted time is the real time a student spends working. Activity moments are ink, a question, the tutor looking at the work,
// and live voice talk. Each moment is charged the gap since the previous one, unless that gap is longer than MAX_GAP_SECONDS:
// then the student had walked away or was idle, and the gap counts as zero. Nothing is charged ahead of time: the first moment
// charges 0 s, and when the student stops, nothing is charged after the last moment. A heartbeat is not a moment by itself; it
// only reports the time of the last real moment (see handleHeartbeat). Replaced the "2-minute window forward" rule on 2026-11-14.
export const MAX_GAP_SECONDS = 60;
export const DEFAULT_MONTHLY_CAP_SECONDS = 8 * 3600;
export const LOW_FRACTION = 0.8;
export const MONTH_TIME_ZONE = "America/Vancouver";

export type ActivityKind = "look" | "question" | "heartbeat" | "live_open";
export type SpeechProvider = "elevenlabs" | "openai";

export const wholeSeconds = (at: Date): Date => new Date(Math.floor(at.getTime() / 1000) * 1000);

// Why an event was charged what it was. These labels go into the logs.
export type ChargeReason =
  | "counted" // the gap since the last moment was 60 s or less: all of it is charged
  | "first_activity" // nothing earlier this month to measure from: charged 0
  | "gap_over_60s" // the gap was longer than 60 s: the student was away or idle, charged 0
  | "not_newer" // the moment is not later than one already counted (a repeated report): charged 0
  | "no_activity_reported"; // the request carried no activity (a heartbeat with nothing new, or opening live): charged 0
export type Charge = { seconds: number; reason: ChargeReason; gapSeconds: number | null };

// What an activity moment at `eventAt` adds to the month, given the time of the last counted moment. `eventAt` null means the
// request reported no activity. The last-activity time never moves backwards.
export function chargeFor(lastActivityAt: Date | null, eventAt: Date | null, maxGapSeconds = MAX_GAP_SECONDS): Charge & { lastActivityAt: Date | null } {
  if (!eventAt) return { seconds: 0, reason: "no_activity_reported", gapSeconds: null, lastActivityAt };
  const event = wholeSeconds(eventAt);
  if (!lastActivityAt) return { seconds: 0, reason: "first_activity", gapSeconds: null, lastActivityAt: event };
  const gap = Math.floor((event.getTime() - lastActivityAt.getTime()) / 1000);
  const latest = event.getTime() > lastActivityAt.getTime() ? event : lastActivityAt;
  if (gap <= 0) return { seconds: 0, reason: "not_newer", gapSeconds: gap, lastActivityAt: latest };
  if (gap > maxGapSeconds) return { seconds: 0, reason: "gap_over_60s", gapSeconds: gap, lastActivityAt: latest };
  return { seconds: gap, reason: "counted", gapSeconds: gap, lastActivityAt: latest };
}

// The month a moment belongs to, as the first day in America/Vancouver ("2026-11-01"). It resets on the 1st, Vancouver time.
export function vancouverMonth(at: Date): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: MONTH_TIME_ZONE, year: "numeric", month: "2-digit" }).formatToParts(at);
  const year = parts.find((p) => p.type === "year")?.value;
  const month = parts.find((p) => p.type === "month")?.value;
  return `${year}-${month}-01`;
}

// ----- What the app is told -----

export type AllowanceState = "ok" | "low" | "used_up";
export type Allowance = {
  month: string; // "2026-11"
  used_seconds: number;
  cap_seconds: number;
  remaining_seconds: number;
  remaining_minutes: number;
  percent_used: number;
  state: AllowanceState;
  notice: "low" | "used_up" | null; // set on exactly one response per threshold per month
};

export type Usage = {
  countedSeconds: number;
  bonusSeconds: number;
  ttsChars: number;
  lastActivityAt: Date | null; // the last counted activity moment; the next gap is measured from here
  lowNoticed: boolean;
  usedUpNoticed: boolean;
};

export function allowanceOf(month: string, usage: Usage, baseCapSeconds: number, notice: Allowance["notice"] = null): Allowance {
  const cap = Math.max(1, baseCapSeconds + usage.bonusSeconds);
  const used = usage.countedSeconds;
  const remaining = Math.max(0, cap - used);
  const state: AllowanceState = used >= cap ? "used_up" : used >= cap * LOW_FRACTION ? "low" : "ok";
  return {
    month: month.slice(0, 7),
    used_seconds: used,
    cap_seconds: cap,
    remaining_seconds: remaining,
    remaining_minutes: Math.floor(remaining / 60),
    percent_used: Math.min(100, Math.round((used / cap) * 1000) / 10),
    state,
    notice,
  };
}

// ----- The store the server uses -----

export type StudentRecord = {
  id: string;
  planLive: boolean;
  capSeconds: number; // the base monthly cap; top-ups for the month are in usage.bonusSeconds
  disabled: boolean;
  usage: Usage;
};

export const EMPTY_USAGE: Usage = { countedSeconds: 0, bonusSeconds: 0, ttsChars: 0, lastActivityAt: null, lowNoticed: false, usedUpNoticed: false };

export interface StudentStore {
  readonly kind: "postgres" | "memory";
  // The student with this code and this month's usage, or null when there is no such code.
  lookup(code: string, month: string): Promise<StudentRecord | null>;
  // Counts an activity moment (see chargeFor) and returns the month's usage afterwards, with what this event was charged.
  // `at` is when the activity really happened, or null when the request reported none (then nothing is charged).
  chargeActivity(studentId: string, month: string, at: Date | null, kind: ActivityKind): Promise<{ usage: Usage; charge: Charge }>;
  // Adds the characters of one spoken utterance (ElevenLabs bills per character, so those are also kept separately);
  // returns the month's running total.
  addSpeech(studentId: string, month: string, chars: number, provider: SpeechProvider): Promise<number>;
  // True for exactly one caller per student, month and threshold.
  claimNotice(studentId: string, month: string, which: "low" | "used_up"): Promise<boolean>;
}

const toDate = (value: unknown): Date | null => (value ? new Date(String(value)) : null);
const toInt = (value: unknown): number => Number(value ?? 0);

function usageFromRow(row: Record<string, unknown>): Usage {
  return {
    countedSeconds: toInt(row.counted_seconds),
    bonusSeconds: toInt(row.bonus_seconds),
    ttsChars: toInt(row.tts_chars),
    lastActivityAt: toDate(row.last_activity_at),
    lowNoticed: Boolean(row.low_noticed),
    usedUpNoticed: Boolean(row.used_up_noticed),
  };
}

const LOOKUP_SQL = `
select s.id, s.plan_live, s.monthly_cap_seconds, s.disabled_at is not null as disabled,
       coalesce(u.counted_seconds, 0) as counted_seconds, coalesce(u.bonus_seconds, 0) as bonus_seconds,
       coalesce(u.tts_chars, 0) as tts_chars, u.last_activity_at,
       u.low_notice_at is not null as low_noticed, u.used_up_notice_at is not null as used_up_noticed
from students s
left join usage_months u on u.student_id = s.id and u.month = $2::date
where s.code = $1`;

// One statement, one round trip, atomic. A new month starts a new row at zero. The charge is the gap between the new moment ($3)
// and the month's last counted moment, when that gap is 1 to 60 seconds ($4); a first moment, a longer gap, an older or equal
// moment, or a null $3 (no activity reported) charges nothing. The last-activity time only moves forward. The `before` CTE
// reads the row as it was, for the log line (what was charged, and why); the row update itself is the atomic part, so under
// two simultaneous requests the billed total is exact and only that log line can be off.
const CHARGE_SQL = `
with before as (
  select counted_seconds, last_activity_at from usage_months where student_id = $1::bigint and month = $2::date
)
insert into usage_months as u (student_id, month, counted_seconds, last_activity_at, looks, questions)
values ($1::bigint, $2::date, 0, $3::timestamptz, $5::int, $6::int)
on conflict (student_id, month) do update set
  counted_seconds = u.counted_seconds + case
    when $3::timestamptz is not null and u.last_activity_at is not null
         and $3::timestamptz > u.last_activity_at
         and $3::timestamptz - u.last_activity_at <= make_interval(secs => $4::int)
    then floor(extract(epoch from ($3::timestamptz - u.last_activity_at)))::int
    else 0
  end,
  last_activity_at = greatest(u.last_activity_at, $3::timestamptz),
  looks = u.looks + $5::int,
  questions = u.questions + $6::int,
  updated_at = now()
returning counted_seconds, bonus_seconds, tts_chars, last_activity_at,
          low_notice_at is not null as low_noticed, used_up_notice_at is not null as used_up_noticed,
          (select last_activity_at from before) as before_activity_at,
          (select counted_seconds from before) as before_counted_seconds`;

const SPEECH_SQL = `
insert into usage_months as u (student_id, month, tts_chars, tts_chars_eleven, tts_utterances)
values ($1::bigint, $2::date, $3::int, $4::int, 1)
on conflict (student_id, month) do update set
  tts_chars = u.tts_chars + $3::int,
  tts_chars_eleven = u.tts_chars_eleven + $4::int,
  tts_utterances = u.tts_utterances + 1,
  updated_at = now()
returning tts_chars`;

const CLAIM_LOW_SQL = `
update usage_months set low_notice_at = now()
where student_id = $1::bigint and month = $2::date and low_notice_at is null
returning student_id`;

const CLAIM_USED_UP_SQL = `
update usage_months set used_up_notice_at = now()
where student_id = $1::bigint and month = $2::date and used_up_notice_at is null
returning student_id`;

export class PgStudentStore implements StudentStore {
  readonly kind = "postgres" as const;
  constructor(private readonly db: Db) {}

  async lookup(code: string, month: string): Promise<StudentRecord | null> {
    // A read changes nothing, so one retry on a failed or slow first try is safe (a sleeping Neon compute can drop the first call).
    let rows: Record<string, unknown>[];
    try {
      rows = await this.db.query(LOOKUP_SQL, [code, month]);
    } catch {
      rows = await this.db.query(LOOKUP_SQL, [code, month]);
    }
    const row = rows[0];
    if (!row) return null;
    return {
      id: String(row.id),
      planLive: Boolean(row.plan_live),
      capSeconds: toInt(row.monthly_cap_seconds),
      disabled: Boolean(row.disabled),
      usage: usageFromRow(row),
    };
  }

  async chargeActivity(studentId: string, month: string, at: Date | null, kind: ActivityKind): Promise<{ usage: Usage; charge: Charge }> {
    const looks = kind === "look" ? 1 : 0;
    const questions = kind === "question" ? 1 : 0;
    const eventAt = at ? wholeSeconds(at) : null;
    const rows = await this.db.query(CHARGE_SQL, [studentId, month, eventAt ? eventAt.toISOString() : null, MAX_GAP_SECONDS, looks, questions]);
    const row = rows[0] ?? {};
    const usage = usageFromRow(row);
    // The reason comes from the row as it was before; the seconds are what the total actually grew by.
    const reason = chargeFor(toDate(row.before_activity_at), eventAt);
    const grew = usage.countedSeconds - toInt(row.before_counted_seconds);
    return { usage, charge: { seconds: grew, reason: reason.reason, gapSeconds: reason.gapSeconds } };
  }

  async addSpeech(studentId: string, month: string, chars: number, provider: SpeechProvider): Promise<number> {
    const rows = await this.db.query(SPEECH_SQL, [studentId, month, chars, provider === "elevenlabs" ? chars : 0]);
    return toInt(rows[0]?.tts_chars);
  }

  async claimNotice(studentId: string, month: string, which: "low" | "used_up"): Promise<boolean> {
    const rows = await this.db.query(which === "low" ? CLAIM_LOW_SQL : CLAIM_USED_UP_SQL, [studentId, month]);
    return rows.length > 0;
  }
}
