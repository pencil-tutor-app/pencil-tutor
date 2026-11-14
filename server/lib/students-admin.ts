import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Db, Row } from "./db.js";
import { allowanceOf, codeHash, generateCode, DEFAULT_MONTHLY_CAP_SECONDS, type Usage } from "./students.js";

// What Edward's local admin script (scripts/admin.ts) does to the database: create, list, top up, disable, enable, set the
// live plan, delete test codes, and apply the migrations. It is never imported by the server's request path.

export type AdminStudent = {
  code: string;
  hash: string;
  planLive: boolean;
  capSeconds: number;
  disabled: boolean;
  createdAt: string;
  usedSeconds: number;
  bonusSeconds: number;
  remainingMinutes: number;
  state: string;
  ttsChars: number;
};

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");

// Splits a migration file into single statements (the HTTP driver runs one statement per call). Comment lines are dropped.
export function splitStatements(sql: string): string[] {
  return sql
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export class StudentAdmin {
  constructor(private readonly db: Db) {}

  // Applies every migration file not yet recorded. Returns the names it applied.
  async migrate(): Promise<string[]> {
    await this.db.query("create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())");
    const done = new Set((await this.db.query("select name from schema_migrations")).map((r) => String(r.name)));
    const applied: string[] = [];
    for (const file of readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort()) {
      if (done.has(file)) continue;
      for (const statement of splitStatements(readFileSync(join(MIGRATIONS_DIR, file), "utf8"))) await this.db.query(statement);
      await this.db.query("insert into schema_migrations (name) values ($1) on conflict (name) do nothing", [file]);
      applied.push(file);
    }
    return applied;
  }

  async create(options: { capSeconds?: number; planLive?: boolean } = {}): Promise<{ code: string; hash: string }> {
    const capSeconds = options.capSeconds ?? DEFAULT_MONTHLY_CAP_SECONDS;
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const code = generateCode();
      const rows = await this.db.query(
        "insert into students (code, monthly_cap_seconds, plan_live) values ($1, $2::int, $3::boolean) on conflict (code) do nothing returning code",
        [code, capSeconds, options.planLive ?? false],
      );
      if (rows.length > 0) return { code, hash: codeHash(code) };
    }
    throw new Error("could not find an unused code after 8 tries");
  }

  async list(month: string): Promise<AdminStudent[]> {
    const rows = await this.db.query(
      `select s.code, s.plan_live, s.monthly_cap_seconds, s.disabled_at is not null as disabled, s.created_at,
              coalesce(u.counted_seconds, 0) as counted_seconds, coalesce(u.bonus_seconds, 0) as bonus_seconds,
              coalesce(u.tts_chars, 0) as tts_chars
       from students s
       left join usage_months u on u.student_id = s.id and u.month = $1::date
       order by s.id`,
      [month],
    );
    return rows.map((r) => this.shape(r, month));
  }

  private shape(r: Row, month: string): AdminStudent {
    const usage: Usage = {
      countedSeconds: Number(r.counted_seconds),
      bonusSeconds: Number(r.bonus_seconds),
      ttsChars: Number(r.tts_chars),
      coveredUntil: null,
      lowNoticed: false,
      usedUpNoticed: false,
    };
    const allowance = allowanceOf(month, usage, Number(r.monthly_cap_seconds));
    return {
      code: String(r.code),
      hash: codeHash(String(r.code)),
      planLive: Boolean(r.plan_live),
      capSeconds: Number(r.monthly_cap_seconds),
      disabled: Boolean(r.disabled),
      createdAt: new Date(String(r.created_at)).toISOString(),
      usedSeconds: usage.countedSeconds,
      bonusSeconds: usage.bonusSeconds,
      remainingMinutes: allowance.remaining_minutes,
      state: allowance.state,
      ttsChars: usage.ttsChars,
    };
  }

  // Adds seconds to this month's allowance only (the next month starts from the base cap again). Clears the notices that the
  // new headroom makes true again, so the student hears "low" and "used up" again if they run out of the extra time.
  async topUp(code: string, month: string, seconds: number): Promise<AdminStudent | null> {
    const found = await this.db.query("select id from students where code = $1", [code]);
    const id = found[0]?.id;
    if (id === undefined) return null;
    await this.db.query(
      `insert into usage_months as u (student_id, month, bonus_seconds) values ($1::bigint, $2::date, $3::int)
       on conflict (student_id, month) do update set bonus_seconds = u.bonus_seconds + $3::int, updated_at = now()`,
      [String(id), month, seconds],
    );
    await this.db.query(
      `update usage_months u set
         used_up_notice_at = case when u.counted_seconds < s.monthly_cap_seconds + u.bonus_seconds then null else u.used_up_notice_at end,
         low_notice_at = case when u.counted_seconds < 0.8 * (s.monthly_cap_seconds + u.bonus_seconds) then null else u.low_notice_at end
       from students s
       where s.id = u.student_id and u.student_id = $1::bigint and u.month = $2::date`,
      [String(id), month],
    );
    return (await this.list(month)).find((s) => s.code === code) ?? null;
  }

  async setDisabled(code: string, disabled: boolean): Promise<boolean> {
    const rows = await this.db.query(
      "update students set disabled_at = case when $2::boolean then coalesce(disabled_at, now()) else null end where code = $1 returning id",
      [code, disabled],
    );
    return rows.length > 0;
  }

  async setLive(code: string, live: boolean): Promise<boolean> {
    const rows = await this.db.query("update students set plan_live = $2::boolean where code = $1 returning id", [code, live]);
    return rows.length > 0;
  }

  // Removes a code and its usage rows. For test codes; real students are disabled, not deleted.
  async remove(code: string): Promise<boolean> {
    const rows = await this.db.query("delete from students where code = $1 returning id", [code]);
    return rows.length > 0;
  }
}
