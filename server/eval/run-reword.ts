// Eval for the spoken-hint rewrite (lib/record/reword.ts). A script, not a CI test: it makes real model calls and costs a few cents.
//
// For each of the wrong-work fixture pages it runs the real handleWatch with a consenting synthetic record, so the watch call
// decides first and the rewrite follows exactly as in production. It saves, per request: what the watch call decided, the spoken
// hint the watch call wrote, the spoken hint that was finally sent, and the rewrite's outcome label. The pass rule (see
// docs/tutor-memory-plan.md section 9) is applied by READING the pairs, not by code: every accepted rewrite must keep the slip,
// add no corrected value, and mention no earlier lesson. This script prints the counts and writes the pairs for that reading.
//
// Keys are read from the environment, never printed. Run it with the production env loaded exec-only:
//   vercel --cwd <main checkout>/server env run -e production --scope edwards-projects-7fd27381 -- \
//     server/node_modules/.bin/tsx server/eval/run-reword.ts --reps 2 --run memory-reword
// Options: --reps N (default 2)  --run <name>  --concurrency N (default 3)  --model <openai model> (default gpt-6-luna)

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { LanguageModel } from "ai";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import { realModels, type ModelFactory } from "../lib/models.js";
import type { Deleted, LookArgs, LookResult, Note, RecordStore, Status } from "../lib/record/store.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { handleWatch } from "../lib/watch.js";

const HERE = new URL(".", import.meta.url).pathname;
const FIXTURES = `${HERE}fixtures/`;
const TOKEN = "K7MQ2XAB";
const students = new MemoryStudentStore();
students.add(TOKEN, { capSeconds: 1_000_000_000 });

const arg = (name: string, fallback: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? (process.argv[i + 1] ?? fallback) : fallback;
};

const NOTE_SETS: Record<string, Note[]> = {
  notes: [
    { id: "1", sessionOn: "2026-11-09", body: "Starts to doubt herself when told she is wrong; open with what is right.", pinned: true },
    { id: "2", sessionOn: "2026-11-02", body: "Likes short hints and does well when asked a question rather than told.", pinned: false },
  ],
  priming: [
    { id: "1", sessionOn: "2026-11-09", body: "Often drops the minus sign when it multiplies a bracket.", pinned: false },
    { id: "2", sessionOn: "2026-11-02", body: "Tends to rush the last line and skip checking.", pinned: false },
  ],
};

// A record that has always been agreed to and holds the given notes. Nothing is stored.
class FixedRecord implements RecordStore {
  readonly kind = "stub" as const;
  constructor(private readonly notes: Note[]) {}
  async recordLook(_id: string, _v: string, args: LookArgs): Promise<LookResult> {
    return { consented: true, notes: args.wantNotes ? this.notes : [] };
  }
  async recordQuestion(): Promise<boolean> {
    return true;
  }
  async status(): Promise<Status> {
    return { consent: null, notes: 0, recent: [] };
  }
  async grant(): Promise<void> {}
  async withdraw(): Promise<Deleted> {
    return { withdrawn: 0, hints: 0, attempts: 0, notes: 0 };
  }
  async erase(): Promise<Deleted> {
    return { withdrawn: 0, hints: 0, attempts: 0, notes: 0 };
  }
}

type Page = {
  id: string; file: string; problem_id: string; category: string; error_type: string | null; wrong_line: number | null;
  lines: { index: number; box: { x: number; y: number; w: number; h: number } }[]; rows: string[];
};

const logsByRequest = new Map<string, Record<string, unknown>>();
setLogSink((line) => {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  if (typeof parsed.request_id === "string") logsByRequest.set(parsed.request_id, parsed);
});

// Wraps the real model so the text of the FIRST call (the watch decision) is kept: that is the spoken hint before any rewrite.
function capturing(): { models: ModelFactory; firstText: () => string | null } {
  let first: string | null = null;
  const models: ModelFactory = {
    ...realModels,
    language(cfg, apiKey) {
      const inner = realModels.language(cfg, apiKey) as unknown as {
        doGenerate: (options: unknown) => Promise<{ content: { type: string; text?: string }[] }>;
      };
      const original = inner.doGenerate.bind(inner);
      return Object.assign(Object.create(inner as object), {
        doGenerate: async (options: unknown) => {
          const out = await original(options);
          if (first === null) first = out.content.map((c) => (c.type === "text" ? (c.text ?? "") : "")).join("");
          return out;
        },
      }) as unknown as LanguageModel;
    },
  };
  return { models, firstText: () => first };
}

async function runOne(page: Page, set: string, rep: number) {
  const png = readFileSync(`${FIXTURES}${page.file}`);
  const cap = capturing();
  const deps: Deps = {
    env: {
      OPENAI_API_KEY: process.env.OPENAI_API_KEY,
      WATCH_MODEL: arg("model", "gpt-6-luna"),
      STUDENT_RECORD: "on",
      STUDENT_RECORD_REWORD: "on",
    },
    models: cap.models,
    students,
    record: new FixedRecord(NOTE_SETS[set] ?? []),
  };
  const body = {
    session_id: `reword-${rep}`, problem_id: page.problem_id, drawing_revision: rep, image_png_base64: png.toString("base64"),
    lines: page.lines.map((l) => ({ ...l, last_stroke_at: "2026-11-14T00:00:00Z" })), history: [], client_time: "2026-11-14T00:00:05Z",
  };
  const res = await handleWatch(
    new Request("https://eval.test/api/watch", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` }, body: JSON.stringify(body) }),
    deps,
  );
  const out = (await res.json()) as Record<string, unknown>;
  const log = logsByRequest.get(String(out.request_id)) ?? {};
  let original: string | null = null;
  try {
    original = (JSON.parse(cap.firstText() ?? "{}") as { hint_spoken?: string | null }).hint_spoken ?? null;
  } catch {
    original = null;
  }
  return {
    page: page.id, error_type: page.error_type, wrong_line: page.wrong_line, set, rep, status: res.status,
    action: out.action, line: out.line, hint_written: out.hint_written,
    original_spoken: original, final_spoken: out.hint_spoken, reword: log.reword ?? null,
    reword_model_ms: log.reword_model_ms ?? null, reword_est_cost_usd: log.reword_est_cost_usd ?? null,
    watch_model_ms: log.model_ms ?? null, latency_ms: out.latency_ms,
  };
}

async function main() {
  if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is not set (load it exec-only)");
  const reps = Number(arg("reps", "2"));
  const concurrency = Number(arg("concurrency", "3"));
  const run = arg("run", "memory-reword");
  const pages = (JSON.parse(readFileSync(`${FIXTURES}manifest.json`, "utf8")) as Page[]).filter((p) => p.category === "wrong");
  const jobs = pages.flatMap((p) => Object.keys(NOTE_SETS).flatMap((set) => Array.from({ length: reps }, (_, i) => ({ p, set, rep: i + 1 }))));
  mkdirSync(`${HERE}results`, { recursive: true });
  const path = `${HERE}results/${run}.jsonl`;
  writeFileSync(path, "");
  console.error(`${jobs.length} requests over ${pages.length} wrong pages`);
  let next = 0;
  const rows: Awaited<ReturnType<typeof runOne>>[] = [];
  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (next < jobs.length) {
        const job = jobs[next++]!;
        const row = await runOne(job.p, job.set, job.rep);
        rows.push(row);
        appendFileSync(path, JSON.stringify(row) + "\n");
      }
    }),
  );
  const interrupts = rows.filter((r) => r.action === "interrupt");
  const by = (label: (r: (typeof rows)[number]) => boolean) => interrupts.filter(label).length;
  const reasons = new Map<string, number>();
  for (const r of interrupts) reasons.set(String(r.reword), (reasons.get(String(r.reword)) ?? 0) + 1);
  const ms = interrupts.map((r) => Number(r.reword_model_ms ?? 0)).filter(Boolean).sort((a, b) => a - b);
  const cost = interrupts.reduce((a, r) => a + Number(r.reword_est_cost_usd ?? 0), 0);
  console.log(`requests ${rows.length}; interrupts ${interrupts.length}; accepted rewrites ${by((r) => r.reword === "used")}; changed text ${by((r) => r.final_spoken !== r.original_spoken)}`);
  console.log(`reword outcomes: ${[...reasons].map(([k, v]) => `${k}=${v}`).join(", ")}`);
  console.log(`second call: median ${ms[Math.floor(ms.length / 2)] ?? "n/a"} ms, max ${ms.at(-1) ?? "n/a"} ms, estimated cost $${cost.toFixed(5)} for ${ms.length} calls`);
  console.log(`pairs written to ${path} for reading`);
}

main().catch((err) => {
  console.error(err instanceof Error ? `${err.name}: ${err.message}` : "eval failed");
  process.exit(1);
});
