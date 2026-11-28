// Show me how, one real-model pass (docs/show-me-plan.md, decision 4). A script, not a CI test: it makes real API calls and costs money.
// It drives the SAME handlers the server runs (handleTeach action "solve", handleConsult) with the real AI SDK models, so the prompts,
// the schema, the blind solver, the comparer and the acceptance rule are the production ones. Nothing here plays or records sound.
//
//   solve    the three hard cases of the linear-algebra bank, submitted as OWN problems (typed text, no answer key), several repeats each:
//            la-04 (inconsistent: no solution), la-05 (free variable: infinitely many), la-02 (one answer). The bank's own answers are
//            the ground truth; the table also records what the checker said (accepted or not_checked, and its flags).
//   routing  /api/consult with show_me_ok on a real page picture: does the page reader answer SHOW_ME exactly when the student asks to
//            be shown or has no idea, and never for "is this right?" or a question about a line? And for an app that does not say
//            show_me_ok, never?
//
// Keys come from the environment (never printed), loaded exec-only:
//   server/node_modules/.bin/tsx --env-file=/path/to/env server/eval/run-show-me-eval.ts --out <results.jsonl> --details <details.json>
// Options: --reps N (default 3)   --max-calls N (default 120, counted at the provider)   --budget USD (default 1.5, stops when the estimate passes it)
// Results: --out (labels, counts and cost, no text), --details (also the statements and answers of these public bank problems, for the write-up).

import { randomBytes } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import type { LanguageModel } from "ai";
import { handleConsult } from "../lib/consult.js";
import type { Env } from "../lib/config.js";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import { realModels, type ModelFactory } from "../lib/models.js";
import { findProblem } from "../lib/problems.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { handleTeach } from "../lib/teach.js";

const HERE = new URL(".", import.meta.url).pathname;
const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const OUT = arg("out");
const DETAILS = arg("details");
if (!OUT || !DETAILS) throw new Error("--out <results.jsonl> and --details <details.json> are required");
const REPS = Number(arg("reps", "3"));
const MAX_CALLS = Number(arg("max-calls", "120"));
const BUDGET = Number(arg("budget", "1.5"));
if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is not set (load it with --env-file)");

const ENV: Env = { OPENAI_API_KEY: process.env.OPENAI_API_KEY, TEACH_SEAL_KEY: randomBytes(32).toString("hex") };

let providerCalls = 0;
let spent = 0;
function counting(base: ModelFactory): ModelFactory {
  return {
    ...base,
    language(cfg, key) {
      const model = base.language(cfg, key) as unknown as Record<string | symbol, unknown>;
      return new Proxy(model, {
        get(target, prop) {
          if (prop === "doGenerate") {
            return async (...args: unknown[]) => {
              providerCalls += 1;
              if (providerCalls > MAX_CALLS) throw new Error(`call cap ${MAX_CALLS} reached`);
              if (spent > BUDGET) throw new Error(`budget ${BUDGET} USD reached`);
              return (target.doGenerate as (...a: unknown[]) => Promise<unknown>).apply(target, args);
            };
          }
          const value = target[prop];
          return typeof value === "function" ? (value as (...a: unknown[]) => unknown).bind(target) : value;
        },
      }) as unknown as LanguageModel;
    },
  };
}

const TOKEN = "K7MQ2XAB";
const students = new MemoryStudentStore();
students.add(TOKEN, { capSeconds: 1_000_000_000 });
const deps: Deps = { env: ENV, models: counting(realModels), students };

const logsByRequest = new Map<string, Record<string, unknown>>();
setLogSink((line) => {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  if (typeof parsed.request_id === "string" && parsed.event === undefined) logsByRequest.set(parsed.request_id, parsed);
});

const post = (path: string, body: unknown) =>
  new Request(`https://eval.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` }, body: JSON.stringify(body) });

const METRIC = /^(status|outcome|reason|latency_ms|model|level|check_model|problem_kind|kind|reference|action|checker|checker_equivalent|checker_single_answer|checker_wrong_step|show_me|steps|est_cost_usd|.*(_ms|_tokens|_est_cost_usd))$/;
const rows: Record<string, unknown>[] = [];
const details: Record<string, unknown>[] = [];

async function call(step: string, handler: (r: Request, d: Deps) => Promise<Response>, path: string, body: unknown) {
  const res = await handler(post(path, body), deps);
  const json = (await res.json()) as Record<string, unknown>;
  const log = logsByRequest.get(String(json.request_id)) ?? {};
  if (typeof log.est_cost_usd === "number") spent += log.est_cost_usd;
  const row = { step, http: res.status, ...Object.fromEntries(Object.entries(log).filter(([k]) => METRIC.test(k))), providerCallsSoFar: providerCalls, spentSoFar: Math.round(spent * 1e4) / 1e4 };
  rows.push(row);
  appendFileSync(OUT!, JSON.stringify(row) + "\n");
  console.error(`${step}: http ${res.status} ${json.error ?? (json.solution === null ? json.reason : json.show_me ? "SHOW_ME" : "ok")} calls=${providerCalls} spent=${spent.toFixed(4)}`);
  return { json, row };
}

const SOLVE_CASES = [
  { id: "la-04", label: "inconsistent system (no solution)" },
  { id: "la-05", label: "free-variable system (infinitely many)" },
  { id: "la-02", label: "single answer" },
];

async function solveCases() {
  for (const c of SOLVE_CASES) {
    const bank = findProblem(c.id)!;
    for (let rep = 1; rep <= REPS; rep++) {
      const { json, row } = await call(`solve:${c.id}:${rep}`, handleTeach, "/api/teach", {
        action: "solve", session_id: "show-me-eval", course: "linear-algebra", problem_id: "own:linear-algebra", problem_text: bank.prompt_plain,
      });
      row.case = c.label;
      details.push({ step: `solve:${c.id}:${rep}`, case: c.label, statement: bank.prompt_plain, bank_answer: bank.final_answer, solution: json.solution, reason: json.reason, checker: row.checker, flags: [row.checker_equivalent, row.checker_single_answer, row.checker_wrong_step] });
    }
  }
}

const PAGE = readFileSync(`${HERE}fixtures/courses/linear-algebra__la-07__correct.png`).toString("base64");
const ROUTING: { say: string; expect: "show_me" | "words"; recent?: { role: "student" | "tutor"; text: string }[]; showMeOk?: boolean }[] = [
  { say: "I have no idea where to start.", expect: "show_me" },
  { say: "Can you show me how to do this one?", expect: "show_me" },
  { say: "I give up, just show me the solution please.", expect: "show_me" },
  { say: "Yes please.", expect: "show_me", recent: [{ role: "tutor", text: "Nothing new since I last looked. Want me to show you how?" }] },
  { say: "Is my last line right?", expect: "words" },
  { say: "What should I do next?", expect: "words" },
  { say: "Why did the sign change on that line?", expect: "words" },
  { say: "I have no idea where to start.", expect: "words", showMeOk: false },
];

async function routing() {
  const la07 = findProblem("la-07")!;
  for (const [index, r] of ROUTING.entries()) {
    for (let rep = 1; rep <= 2; rep++) {
      const withApp = r.showMeOk !== false;
      const { json, row } = await call(`route:${index + 1}:${rep}`, handleConsult, "/api/consult", {
        session_id: "show-me-eval", problem_id: la07.id, drawing_revision: 1, image_png_base64: PAGE, question: r.say, recent: r.recent ?? [],
        ...(withApp ? { show_me_ok: true } : {}),
      });
      const got = json.show_me === true ? "show_me" : "words";
      row.expected = r.expect;
      row.got = got;
      row.show_me_ok_sent = withApp;
      row.ok = got === r.expect;
      details.push({ step: `route:${index + 1}:${rep}`, said: r.say, show_me_ok_sent: withApp, expected: r.expect, got, answer_chars: String(json.answer_text ?? "").length });
    }
  }
}

async function main() {
  await solveCases();
  await routing();
  writeFileSync(DETAILS!, JSON.stringify({ providerCalls, spent: Math.round(spent * 1e4) / 1e4, rows, details }, null, 1));
  console.error(`done: ${providerCalls} provider calls, about ${spent.toFixed(4)} USD estimated. Details in ${DETAILS}`);
}

main().catch((err) => {
  writeFileSync(DETAILS!, JSON.stringify({ providerCalls, spent, rows, details, stoppedBy: err instanceof Error ? err.message : "failed" }, null, 1));
  console.error(err instanceof Error ? `${err.name}: ${err.message}` : "eval failed");
  console.error(`provider calls made: ${providerCalls}, spent about ${spent.toFixed(4)} USD`);
  process.exit(1);
});
