import { openDb } from "../lib/db.js";
import { StudentAdmin, type AdminStudent } from "../lib/students-admin.js";
import { DEFAULT_MONTHLY_CAP_SECONDS, isValidCode, normalizeCode, vancouverMonth } from "../lib/students.js";

// Edward's local admin tool for student codes. Run it through scripts/codes, which loads the production database address
// exec-only (never printed, never written to a file):  scripts/codes list
// No student names are stored or printed: a student is a code. Edward keeps the code-to-student list offline.

const USAGE = `Pencil Tutor student codes

  scripts/codes migrate                         create or update the tables (safe to repeat)
  scripts/codes create [--count N] [--hours H | --minutes M] [--live]
                                                make new codes (default 8 hours a month, live voice off)
  scripts/codes list                            every code, this month's use, minutes left
  scripts/codes topup CODE --hours H | --minutes M
                                                add time to this month only
  scripts/codes disable CODE                    turn a code off (the student sees "turned off")
  scripts/codes enable CODE                     turn it back on
  scripts/codes live CODE on|off                allow or forbid the premium live voice
  scripts/codes delete CODE --yes               remove a code and its usage (for test codes)

CODE can be typed with or without the dash, in any case.`;

const show = (code: string) => `${code.slice(0, 4)}-${code.slice(4)}`;

function option(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}

// --hours or --minutes (decimals allowed) as whole seconds.
function secondsFrom(args: string[]): number | undefined {
  const hours = option(args, "--hours");
  const minutes = option(args, "--minutes");
  const value = hours !== undefined ? Number(hours) * 3600 : minutes !== undefined ? Number(minutes) * 60 : undefined;
  if (value === undefined) return undefined;
  if (!Number.isFinite(value) || value <= 0) throw new Error("the amount must be a number greater than zero");
  return Math.round(value);
}

function codeArg(args: string[]): string {
  const raw = args[0];
  if (!raw || raw.startsWith("--")) throw new Error("give a CODE");
  const code = normalizeCode(raw);
  if (!isValidCode(code)) throw new Error("that does not look like a code (8 letters and digits)");
  return code;
}

function table(rows: AdminStudent[]): string {
  if (rows.length === 0) return "no codes yet";
  const header = ["code", "log id", "state", "used", "left", "cap/mo", "live", "on", "voice chars"];
  const body = rows.map((s) => [
    show(s.code),
    s.hash,
    s.state,
    `${Math.round(s.usedSeconds / 60)} min`,
    `${s.remainingMinutes} min`,
    `${Math.round((s.capSeconds + s.bonusSeconds) / 60)} min`,
    s.planLive ? "yes" : "no",
    s.disabled ? "OFF" : "yes",
    String(s.ttsChars),
  ]);
  const widths = header.map((h, i) => Math.max(h.length, ...body.map((r) => (r[i] ?? "").length)));
  const line = (cells: string[]) => cells.map((c, i) => c.padEnd(widths[i] ?? 0)).join("  ");
  return [line(header), ...body.map(line)].join("\n");
}

async function main(argv: string[]): Promise<number> {
  const [command, ...args] = argv;
  if (!command || command === "help" || command === "--help") {
    console.log(USAGE);
    return 0;
  }
  const db = openDb(process.env);
  if (!db) {
    console.error("DATABASE_URL is not set. Run this through scripts/codes so the production database address is loaded.");
    return 2;
  }
  const admin = new StudentAdmin(db);
  const month = vancouverMonth(new Date());

  switch (command) {
    case "migrate": {
      const applied = await admin.migrate();
      console.log(applied.length ? `applied: ${applied.join(", ")}` : "nothing to apply: the tables are up to date");
      return 0;
    }
    case "create": {
      const count = Number(option(args, "--count") ?? "1");
      if (!Number.isInteger(count) || count < 1 || count > 50) throw new Error("--count must be a whole number from 1 to 50");
      const capSeconds = secondsFrom(args) ?? DEFAULT_MONTHLY_CAP_SECONDS;
      const planLive = args.includes("--live");
      for (let i = 0; i < count; i += 1) {
        const made = await admin.create({ capSeconds, planLive });
        console.log(`${show(made.code)}   log id ${made.hash}   ${Math.round(capSeconds / 60)} min a month   live voice ${planLive ? "on" : "off"}`);
      }
      return 0;
    }
    case "list": {
      console.log(`month ${month.slice(0, 7)} (America/Vancouver)`);
      console.log(table(await admin.list(month)));
      return 0;
    }
    case "topup": {
      const code = codeArg(args);
      const seconds = secondsFrom(args);
      if (seconds === undefined) throw new Error("give --hours H or --minutes M");
      const after = await admin.topUp(code, month, seconds);
      if (!after) {
        console.error(`no such code: ${show(code)}`);
        return 1;
      }
      console.log(`${show(code)}: added ${Math.round(seconds / 60)} min for ${month.slice(0, 7)}; ${after.remainingMinutes} min left (${after.state})`);
      return 0;
    }
    case "disable":
    case "enable": {
      const code = codeArg(args);
      if (!(await admin.setDisabled(code, command === "disable"))) {
        console.error(`no such code: ${show(code)}`);
        return 1;
      }
      console.log(`${show(code)}: ${command === "disable" ? "turned off" : "turned back on"}`);
      return 0;
    }
    case "live": {
      const code = codeArg(args);
      const setting = args[1];
      if (setting !== "on" && setting !== "off") throw new Error("say on or off");
      if (!(await admin.setLive(code, setting === "on"))) {
        console.error(`no such code: ${show(code)}`);
        return 1;
      }
      console.log(`${show(code)}: live voice ${setting}`);
      return 0;
    }
    case "delete": {
      const code = codeArg(args);
      if (!args.includes("--yes")) throw new Error("this removes the code and its usage for good; add --yes to confirm");
      if (!(await admin.remove(code))) {
        console.error(`no such code: ${show(code)}`);
        return 1;
      }
      console.log(`${show(code)}: deleted`);
      return 0;
    }
    default:
      console.error(`unknown command "${command}"\n\n${USAGE}`);
      return 2;
  }
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    // The database layer only ever throws labels, so this cannot print the connection string.
    const label = err instanceof Error ? (err as { label?: string }).label ?? err.message : "unknown error";
    console.error(`error: ${label}`);
    process.exit(1);
  },
);
