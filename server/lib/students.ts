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

// A counted minute is a minute with a problem open and recent activity: ink, a question or a look within the last 2 minutes.
// Every activity event keeps the meter running for ACTIVITY_WINDOW_SECONDS after it. Counted time is the total length of the
// union of those windows, and each event is charged the part of its window that no earlier window already covered.
export const ACTIVITY_WINDOW_SECONDS = 120;
export const DEFAULT_MONTHLY_CAP_SECONDS = 8 * 3600;
export const LOW_FRACTION = 0.8;
export const MONTH_TIME_ZONE = "America/Vancouver";

export type ActivityKind = "look" | "question" | "heartbeat" | "live_open";
export type SpeechProvider = "elevenlabs" | "openai";

export const wholeSeconds = (at: Date): Date => new Date(Math.floor(at.getTime() / 1000) * 1000);

// What an activity event at `at` adds to the month, and where the covered time now ends.
export function chargeFor(coveredUntil: Date | null, at: Date, windowSeconds = ACTIVITY_WINDOW_SECONDS) {
  const start = wholeSeconds(at).getTime();
  const windowEnd = start + windowSeconds * 1000;
  const alreadyCoveredTo = coveredUntil ? Math.max(start, coveredUntil.getTime()) : start;
  const addedSeconds = Math.max(0, Math.floor((windowEnd - alreadyCoveredTo) / 1000));
  return { addedSeconds, coveredUntil: new Date(Math.max(windowEnd, coveredUntil?.getTime() ?? 0)) };
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
  coveredUntil: Date | null;
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

export const EMPTY_USAGE: Usage = { countedSeconds: 0, bonusSeconds: 0, ttsChars: 0, coveredUntil: null, lowNoticed: false, usedUpNoticed: false };

export interface StudentStore {
  readonly kind: "postgres" | "memory";
  // The student with this code and this month's usage, or null when there is no such code.
  lookup(code: string, month: string): Promise<StudentRecord | null>;
  // Counts an activity event (see chargeFor) and returns the month's usage afterwards.
  chargeActivity(studentId: string, month: string, at: Date, kind: ActivityKind): Promise<Usage>;
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
    coveredUntil: toDate(row.covered_until),
    lowNoticed: Boolean(row.low_noticed),
    usedUpNoticed: Boolean(row.used_up_noticed),
  };
}

const LOOKUP_SQL = `
select s.id, s.plan_live, s.monthly_cap_seconds, s.disabled_at is not null as disabled,
       coalesce(u.counted_seconds, 0) as counted_seconds, coalesce(u.bonus_seconds, 0) as bonus_seconds,
       coalesce(u.tts_chars, 0) as tts_chars, u.covered_until,
       u.low_notice_at is not null as low_noticed, u.used_up_notice_at is not null as used_up_noticed
from students s
left join usage_months u on u.student_id = s.id and u.month = $2::date
where s.code = $1`;

// One statement, one round trip, atomic. A new month starts a new row at zero. The first event of a month is charged a full
// window; later events are charged only the part of their window not already covered (the same rule as chargeFor).
const CHARGE_SQL = `
insert into usage_months as u (student_id, month, counted_seconds, covered_until, looks, questions)
values ($1::bigint, $2::date, $4::int, $3::timestamptz + make_interval(secs => $4::int), $5::int, $6::int)
on conflict (student_id, month) do update set
  counted_seconds = u.counted_seconds + greatest(0, floor(extract(epoch from (
    $3::timestamptz + make_interval(secs => $4::int) - greatest($3::timestamptz, coalesce(u.covered_until, $3::timestamptz))
  )))::int),
  covered_until = greatest(coalesce(u.covered_until, $3::timestamptz), $3::timestamptz + make_interval(secs => $4::int)),
  looks = u.looks + $5::int,
  questions = u.questions + $6::int,
  updated_at = now()
returning counted_seconds, bonus_seconds, tts_chars, covered_until,
          low_notice_at is not null as low_noticed, used_up_notice_at is not null as used_up_noticed`;

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

  async chargeActivity(studentId: string, month: string, at: Date, kind: ActivityKind): Promise<Usage> {
    const looks = kind === "look" ? 1 : 0;
    const questions = kind === "question" ? 1 : 0;
    const rows = await this.db.query(CHARGE_SQL, [studentId, month, wholeSeconds(at).toISOString(), ACTIVITY_WINDOW_SECONDS, looks, questions]);
    return usageFromRow(rows[0] ?? {});
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
