import { openDb } from "../lib/db.js";
import { ceilingOf, microsToUsd, usdToMicros } from "../lib/free-config.js";
import { NOTICE_VERSION } from "../lib/record/notice.js";
import { RecordAdmin } from "../lib/record/admin.js";
import { StudentAdmin, type AdminStudent } from "../lib/students-admin.js";
import { DEFAULT_MONTHLY_CAP_SECONDS, isValidCode, normalizeCode, vancouverMonth } from "../lib/students.js";

// Edward's local admin tool for student codes. Run it through scripts/codes, which loads the production database address
// exec-only (never printed, never written to a file):  scripts/codes list
// No student names are stored or printed: a student is a code. Edward keeps the code-to-student list offline.

const USAGE = `Pencil Tutor student codes

  scripts/codes migrate                         create or update the tables (safe to repeat)
  scripts/codes create [--count N] [--hours H | --minutes M] [--live]
                                                make new codes (default 8 hours a month, live voice off)
  scripts/codes list [--free | --all]           the codes you made, this month's use, minutes left (--free: only free codes, --all: both)
  scripts/codes free-spend [--set USD]          this month's estimated cost of all free codes against the ceiling; --set corrects it
                                                (for example after an outage was counted as spend). Also deletes stale address hashes
  scripts/codes topup CODE --hours H | --minutes M
                                                add time to this month only
  scripts/codes disable CODE                    turn a code off (the student sees "turned off")
  scripts/codes enable CODE                     turn it back on
  scripts/codes live CODE on|off                allow or forbid the premium live voice
  scripts/codes delete CODE --yes               remove a code and its usage (for test codes)

Student memory (opt-in; nothing is remembered about a code until a parent or guardian, or an adult student, has agreed):
  scripts/codes consent CODE                    show who agreed, how, which text version, when
  scripts/codes consent --list                  every code: memory on or off
  scripts/codes consent CODE --by parent|adult [--form-date YYYY-MM-DD]
                                                record an agreement from a signed paper form (no name is stored)
  scripts/codes consent CODE --withdraw         turn memory off (add --erase to delete the record as well)
  scripts/codes note add CODE "text" [--on YYYY-MM-DD] [--pin]
                                                a note after a lesson (refused without consent; write it as if the family will read it)
  scripts/codes note list CODE                  scripts/codes note delete CODE ID
  scripts/codes export CODE                     everything stored about a code, as JSON (answers an access request)
  scripts/codes forget CODE --yes [--including-consent-log]
                                                withdraw and delete the record; safe to run again
  scripts/codes forget-inactive [--months 12] [--yes]
                                                codes unused for N months that still hold record data (dry run unless --yes)

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

// One line about the free codes: how many exist, and this month's estimated cost against the ceiling (the stored running total).
async function freeLine(admin: StudentAdmin, month: string): Promise<string> {
  const status = await admin.freeStatus(month);
  const ceiling = ceilingOf(process.env);
  const spent = microsToUsd(status.spentMicros);
  const percent = ceiling.usd > 0 ? Math.round((spent / ceiling.usd) * 1000) / 10 : 100;
  const note = ceiling.source === "invalid_env_using_default" ? " (FREE_MONTHLY_CEILING_USD is not a number: default used)" : "";
  return `free codes: ${status.codes}   free spend this month: $${spent.toFixed(4)} of $${ceiling.usd.toFixed(2)} (${percent}%)   paid calls reserved: ${status.calls}   ElevenLabs characters (not dollars): ${status.elevenChars}${note}`;
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
  const header = ["code", "log id", "origin", "state", "used", "left", "cap/mo", "live", "on", "voice chars"];
  const body = rows.map((s) => [
    show(s.code),
    s.hash,
    s.origin === "free" ? "free" : "hand",
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
      // Free codes can number in the thousands, so by default only the codes made by hand are listed.
      const which = args.includes("--all") ? null : args.includes("--free") ? "free" : "admin";
      console.log(table(await admin.list(month, which)));
      console.log(await freeLine(admin, month));
      return 0;
    }
    case "free-spend": {
      const set = option(args, "--set");
      if (set !== undefined) {
        const usd = Number(set);
        if (!Number.isFinite(usd) || usd < 0) throw new Error("--set must be a number of dollars, 0 or more");
        await admin.setFreeSpend(month, usdToMicros(usd));
        console.log(`free spend for ${month.slice(0, 7)} set to ${usd.toFixed(2)} dollars`);
      }
      console.log(await freeLine(admin, month));
      const purged = await admin.purgeStaleAddresses(new Date());
      console.log(`address hashes deleted (untouched for 2 days): ${purged}`);
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
      const done = await admin.setLive(code, setting === "on");
      if (done === "free") {
        console.error(`${show(code)} is a free code: free codes never get the live voice`);
        return 1;
      }
      if (done === "missing") {
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
    case "consent": {
      const records = new RecordAdmin(db);
      if (args[0] === "--list") {
        console.log("text version now: " + NOTICE_VERSION);
        for (const r of await records.list()) console.log(show(r.code) + "   log id " + r.hash + "   memory " + (r.on ? "ON" : "off") + (r.version && r.version !== NOTICE_VERSION ? "   (agreed to older text " + r.version + ")" : ""));
        return 0;
      }
      const code = codeArg(args);
      const id = await records.idOf(code);
      if (!id) { console.error("no such code: " + show(code)); return 1; }
      if (args.includes("--withdraw")) {
        const done = await records.withdraw(id, args.includes("--erase"));
        console.log(show(code) + ": " + (done.withdrawn ? "memory turned off" : "memory was not on") + (args.includes("--erase") ? "; deleted " + done.attempts + " attempts, " + done.hints + " hint events, " + done.notes + " notes" : ""));
        return 0;
      }
      const by = option(args, "--by");
      if (by !== undefined) {
        if (by !== "parent" && by !== "adult") throw new Error("--by must be parent or adult");
        const formDate = option(args, "--form-date") ?? null;
        if (formDate !== null && !/^\d{4}-\d{2}-\d{2}$/.test(formDate)) throw new Error("--form-date must look like 2026-11-14");
        await records.recordConsent(id, by === "parent" ? "parent_guardian" : "adult_student", formDate);
        console.log(show(code) + ": agreement recorded (" + (by === "parent" ? "parent or guardian" : "adult student") + ", text version " + NOTICE_VERSION + (formDate ? ", form dated " + formDate : "") + "); memory is on");
        return 0;
      }
      const c = await records.consentOf(id);
      console.log(c ? show(code) + ": " + (c.granted ? "agreed" : "withdrawn") + " by " + (c.givenBy ?? "-") + " via " + c.recordedVia + ", text version " + c.noticeVersion + (c.noticeVersion !== NOTICE_VERSION ? " (older than " + NOTICE_VERSION + ": memory is off until they agree again)" : "") + ", " + c.at + (c.evidenceOn ? ", form dated " + c.evidenceOn : "") : show(code) + ": no agreement on record; memory is off");
      return 0;
    }
    case "note": {
      const records = new RecordAdmin(db);
      const [sub, ...rest] = args;
      const code = codeArg(rest);
      const id = await records.idOf(code);
      if (!id) { console.error("no such code: " + show(code)); return 1; }
      if (sub === "add") {
        const text = rest[1];
        if (!text || text.startsWith("--")) throw new Error('give the note in quotes: note add CODE "text"');
        if (text.length > 500) throw new Error("a note is at most 500 characters (it is " + text.length + ")");
        const on = option(rest, "--on") ?? new Intl.DateTimeFormat("en-CA", { timeZone: "America/Vancouver" }).format(new Date());
        if (!/^\d{4}-\d{2}-\d{2}$/.test(on)) throw new Error("--on must look like 2026-11-14");
        const noteId = await records.addNote(id, text, on, rest.includes("--pin"));
        if (!noteId) { console.error(show(code) + ": no agreement on record, so no note was saved"); return 1; }
        console.log(show(code) + ": note " + noteId + " saved for " + on + " (" + text.length + " characters)");
        return 0;
      }
      if (sub === "list") {
        const notes = await records.listNotes(id);
        console.log(notes.length ? notes.map((n) => "#" + n.id + "  " + n.sessionOn + (n.pinned ? "  pinned" : "") + "  " + n.body).join("\n") : "no notes");
        return 0;
      }
      if (sub === "delete") {
        const noteId = rest[1];
        if (!noteId || !/^\d+$/.test(noteId)) throw new Error("give the note id: note delete CODE ID");
        console.log((await records.deleteNote(id, noteId)) ? "note " + noteId + " deleted" : "no such note for that code");
        return 0;
      }
      throw new Error("note add, note list or note delete");
    }
    case "export": {
      const code = codeArg(args);
      const records = new RecordAdmin(db);
      const id = await records.idOf(code);
      if (!id) { console.error("no such code: " + show(code)); return 1; }
      console.log(JSON.stringify(await records.exportAll(id, code), null, 2));
      return 0;
    }
    case "forget": {
      const code = codeArg(args);
      if (!args.includes("--yes")) throw new Error("this deletes the record for good; add --yes to confirm");
      const records = new RecordAdmin(db);
      const id = await records.idOf(code);
      if (!id) { console.error("no such code: " + show(code)); return 1; }
      const done = await records.withdraw(id, true);
      const log = args.includes("--including-consent-log") ? await records.deleteConsentLog(id) : 0;
      console.log(show(code) + ": deleted " + done.attempts + " attempts, " + done.hints + " hint events, " + done.notes + " notes" + (done.withdrawn ? "; memory turned off" : "") + (args.includes("--including-consent-log") ? "; " + log + " consent log rows" : "; consent log kept") + ". Run again if a request was in flight.");
      return 0;
    }
    case "forget-inactive": {
      const months = Number(option(args, "--months") ?? "12");
      if (!Number.isInteger(months) || months < 1 || months > 120) throw new Error("--months must be a whole number from 1 to 120");
      const records = new RecordAdmin(db);
      const stale = await records.inactive(months);
      if (!stale.length) { console.log("no code with record data has been unused for " + months + " months"); return 0; }
      for (const s of stale) {
        if (args.includes("--yes")) {
          const done = await records.withdraw(s.id, true);
          console.log("log id " + s.hash + " (last used " + s.lastUsed.slice(0, 10) + "): deleted " + done.attempts + " attempts, " + done.hints + " hint events, " + done.notes + " notes");
        } else {
          console.log("log id " + s.hash + " (last used " + s.lastUsed.slice(0, 10) + "): would be deleted");
        }
      }
      if (!args.includes("--yes")) console.log("dry run: add --yes to delete");
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
