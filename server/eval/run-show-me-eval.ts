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
// `--set wide` (after the core pass): more linear-algebra answer shapes, problems from other courses, two ill-posed typed problems, and
// hand-planted wrong solutions put through the same check, each case with the question it answers; a case is repeated only until two
// runs agree (a third only when they differ). Total spend is printed after every run.
// `--set diagnose`: for the cases the wide set did not accept, the same three calls with every intermediate kept (what was written, what the
// blind solver said, what the comparer said), to tell a wrong solution from a check that is too strict.
// Options: --set core|wide|diagnose (default core)   --only id,label-start,... (wide: just those solve cases, no planted ones)   --reps N (default 3)   --max-calls N (default 120, counted at the provider)   --budget USD (default 1.5, stops when the estimate passes it)
// Results: --out (labels, counts and cost, no text), --details (also the statements and answers of these public bank problems, for the write-up).

import { randomBytes } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import type { LanguageModel } from "ai";
import { handleConsult } from "../lib/consult.js";
import { apiKeyFor, roleConfig, type Env } from "../lib/config.js";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import { realModels, type ModelFactory } from "../lib/models.js";
import { runStructured } from "../lib/teach-models.js";
import { buildComparerPrompt, buildSolvePrompt, buildSolverPrompt, COMPARER_SYSTEM, ComparerOutputSchema, SolveOutputSchema, solveSystem, SOLVER_SYSTEM, SolverOutputSchema } from "../lib/teach-policy.js";
import { findCourse, findProblem } from "../lib/problems.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import { checkStatement, handleTeach, solveAccepts } from "../lib/teach.js";

const HERE = new URL(".", import.meta.url).pathname;
const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const OUT = arg("out");
const DETAILS = arg("details");
if (!OUT || !DETAILS) throw new Error("--out <results.jsonl> and --details <details.json> are required");
const REPS = Number(arg("reps", "3"));
const SET = arg("set", "core");
const ONLY = arg("only")?.split(",");
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
  const row: Record<string, unknown> = { step, http: res.status, ...Object.fromEntries(Object.entries(log).filter(([k]) => METRIC.test(k))), providerCallsSoFar: providerCalls, spentSoFar: Math.round(spent * 1e4) / 1e4 };
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

// ---------------------------------------------------------------- the wide set

type Wide = { id?: string; course: string; label: string; why: string; text?: string };
const WIDE_CASES: Wide[] = [
  { id: "la-06", course: "linear-algebra", label: "parameter k: a case split for an answer", why: "is a conditional answer (no solution when k = 6, one otherwise) accepted and matched?" },
  { id: "la-20", course: "linear-algebra", label: "Cramer's rule, only z asked", why: "does a partial ask (only z) come back as only z, and does the check agree?" },
  { id: "la-29", course: "linear-algebra", label: "null space basis, rank and nullity", why: "a basis is not unique: does the comparer accept an equivalent basis, or call it a disagreement?" },
  { id: "la-26", course: "linear-algebra", label: "dependence relation (any scalar multiple works)", why: "same question for a relation that is only unique up to scale" },
  { id: "la-28", course: "linear-algebra", label: "rank, column space and row space bases", why: "several parts and several non-unique bases at once" },
  { id: "la-23", course: "linear-algebra", label: "justify: not a subspace (proof style)", why: "a justification, not a number: what does the check do with it?" },
  { id: "c1-37", course: "calculus-1", label: "implicit second derivative at a point", why: "hard exact value outside linear algebra; sign slips are easy" },
  { id: "c1-49", course: "calculus-1", label: "Newton's method, two steps as fractions, then a comparison", why: "exact fractions plus a decimal comparison" },
  { id: "dm-36", course: "discrete-math", label: "Chinese remainder: all x", why: "the answer is a residue class, so many equal forms (x = 18 + 35k)" },
  { id: "dm-41", course: "discrete-math", label: "induction proof", why: "a proof: is it accepted, and is the answer comparison meaningful for a proof?" },
  { id: "dm-51", course: "discrete-math", label: "counting arrangements of STATISTICS", why: "a counting answer a model often gets wrong" },
  { id: "pc12-37", course: "bc-pc-12", label: "log equation with an extraneous root", why: "the classic trap: x = -1 must be rejected" },
  { id: "pc12-73", course: "bc-pc-12", label: "tan x = -1 on [0, 2π): two answers", why: "several answers in one string: single_answer false but accepted" },
  { id: "m9-49", course: "bc-math-9", label: "multi-step word problem with money and percent", why: "a word problem rather than an equation" },
  { course: "bc-math-9", label: "ill-posed: 'Solve for x.' and nothing else", text: "Solve for x.", why: "a student types an incomplete problem: it must not invent one and call it checked" },
  { course: "bc-math-9", label: "ill-posed: one equation, two unknowns", text: "Find x if 2x = y.", why: "underdetermined: an honest answer in terms of y, or a refusal, never a number" },
];

type Planted = { id: string; course: string; label: string; why: string; steps: string[]; finalAnswer: string; shouldAccept: boolean };
const LA02_STEPS = [
  "Write the augmented matrix: [1 1 1 6; 2 -1 1 3; 1 2 -1 2].",
  "R_2 ← R_2 - 2R_1 and R_3 ← R_3 - R_1, giving [1 1 1 6; 0 -3 -1 -9; 0 1 -2 -4].",
  "Swap rows 2 and 3: [1 1 1 6; 0 1 -2 -4; 0 -3 -1 -9].",
  "R_3 ← R_3 + 3R_2, giving [1 1 1 6; 0 1 -2 -4; 0 0 -7 -21].",
  "-7z = -21, so z = 3.",
  "y - 2(3) = -4, so y = 2.",
  "x + 2 + 3 = 6, so x = 1.",
];
const PLANTED: Planted[] = [
  { id: "la-02", course: "linear-algebra", label: "control: la-02 correct, written by hand", why: "does the check accept a correct hand-written solution (false rejections)?", steps: LA02_STEPS, finalAnswer: "(x, y, z) = (1, 2, 3)", shouldAccept: true },
  { id: "la-02", course: "linear-algebra", label: "la-02, last step slips (x = 2) and the answer carries it", why: "a wrong last step and a wrong answer", steps: [...LA02_STEPS.slice(0, 6), "x + 2 + 3 = 6, so x = 2."], finalAnswer: "(x, y, z) = (2, 2, 3)", shouldAccept: false },
  { id: "la-02", course: "linear-algebra", label: "la-02, a wrong row operation but the right final answer", why: "equivalent answers must still be rejected when a step is wrong (first_wrong_step)", steps: [LA02_STEPS[0]!, LA02_STEPS[1]!, LA02_STEPS[2]!, "R_3 ← R_3 + 2R_2, giving [1 1 1 6; 0 1 -2 -4; 0 0 -7 -21].", ...LA02_STEPS.slice(4)], finalAnswer: "(x, y, z) = (1, 2, 3)", shouldAccept: false },
  { id: "la-04", course: "linear-algebra", label: "la-04 (really no solution) claimed to have one", why: "the dangerous direction: a confident wrong answer on an inconsistent system", steps: ["Subtract row 1 from row 2: y + 2z = 3.", "Subtract 2 times row 1 from row 3: y + 2z = 5.", "Take z = 0 as the free choice: y = 3 from the first and y = 5 from the second, so average y = 4... use y = 1.", "Then x = 2 - y - z = 1."], finalAnswer: "(x, y, z) = (1, 1, 0)", shouldAccept: false },
  { id: "la-05", course: "linear-algebra", label: "la-05 free variable with a sign slip in y", why: "a parametric answer that is almost right", steps: ["Subtract twice the first equation from the second: y + z = 3.", "So y = 3 + z.", "Substitute into the first equation: x + (3 + z) + 2z = 4, so x = 1 - 3z.", "Let z = t: (x, y, z) = (1 - 3t, 3 + t, t)."], finalAnswer: "(x, y, z) = (1 - 3t, 3 + t, t), t any real number", shouldAccept: false },
  { id: "c1-37", course: "calculus-1", label: "c1-37 with a dropped minus sign (+25/64)", why: "a sign slip in a calculus value", steps: ["Differentiate x^2 + y^2 = 25: 2x + 2y y' = 0, so y' = -x/y.", "Differentiate again: y'' = -(y - x y')/y^2.", "Substitute y' = -x/y: y'' = (y^2 + x^2)/y^3 = 25/y^3.", "At (3, 4): y'' = 25/64."], finalAnswer: "y'' = 25/64", shouldAccept: false },
  { id: "pc12-37", course: "bc-pc-12", label: "pc12-37 keeping the extraneous root", why: "the trap: does the check catch x = -1 being kept?", steps: ["Combine the logs: log_3 (x(x - 2)) = 1.", "So x(x - 2) = 3, which is x^2 - 2x - 3 = 0.", "Factor: (x - 3)(x + 1) = 0.", "So x = 3 or x = -1."], finalAnswer: "x = 3 or x = -1", shouldAccept: false },
  { id: "pc12-37", course: "bc-pc-12", label: "control: pc12-37 correct, extraneous root rejected", why: "false-rejection control for a case with a trap", steps: ["Combine the logs: log_3 (x(x - 2)) = 1.", "So x(x - 2) = 3, which is x^2 - 2x - 3 = 0.", "Factor: (x - 3)(x + 1) = 0, so x = 3 or x = -1.", "Check in the original: x = -1 makes log_3 (-1) undefined, so reject it; x = 3 works."], finalAnswer: "x = 3", shouldAccept: true },
  { id: "dm-36", course: "discrete-math", label: "dm-36 with k wrong (x = 8 mod 35)", why: "a modular arithmetic slip", steps: ["From x ≡ 3 (mod 5): x = 3 + 5k.", "Then 3 + 5k ≡ 4 (mod 7), so 5k ≡ 1 (mod 7).", "Taking k ≡ 1 (mod 7) works.", "So x = 3 + 5 = 8, and x ≡ 8 (mod 35)."], finalAnswer: "x ≡ 8 (mod 35)", shouldAccept: false },
  { id: "dm-36", course: "discrete-math", label: "control: dm-36 correct", why: "false-rejection control for a congruence answer", steps: ["From x ≡ 3 (mod 5): x = 3 + 5k.", "Then 3 + 5k ≡ 4 (mod 7), so 5k ≡ 1 (mod 7).", "Since 5 · 3 = 15 ≡ 1 (mod 7), k ≡ 3 (mod 7).", "So x = 3 + 15 = 18, and x ≡ 18 (mod 35)."], finalAnswer: "x ≡ 18 (mod 35)", shouldAccept: true },
];

async function wide() {
  // 1. solve, own problems, repeat only until two runs agree
  for (const c of WIDE_CASES.filter((w) => !ONLY || ONLY.some((o) => w.id === o || w.label.startsWith(o)))) {
    const bank = c.id ? findProblem(c.id) : undefined;
    const text = c.text ?? bank!.prompt_plain;
    const seen: string[] = [];
    for (let rep = 1; rep <= 3; rep++) {
      if (rep === 3 && seen[0] === seen[1]) break;
      const label = `solve:${c.id ?? c.label.slice(0, 12).replace(/\W+/g, "-")}:${rep}`;
      const { json, row } = await call(label, handleTeach, "/api/teach", {
        action: "solve", session_id: "show-me-eval", course: c.course, problem_id: `own:${c.course}`, problem_text: text,
      });
      row.case = c.label;
      row.why = c.why;
      seen.push(String(json.reason ?? "accepted"));
      details.push({ step: label, case: c.label, why: c.why, statement: text, bank_answer: bank?.final_answer ?? null, solution: json.solution, reason: json.reason, checker: row.checker, flags: [row.checker_equivalent, row.checker_single_answer, row.checker_wrong_step], est_cost_usd: row.est_cost_usd, spent: row.spentSoFar });
    }
  }
  if (ONLY) return;
  // 2. planted solutions through the same blind solver and comparer and the same acceptance rule
  const cfg = roleConfig("ask", ENV, "advanced");
  const key = apiKeyFor(cfg.provider, ENV)!;
  for (const [index, p] of PLANTED.entries()) {
    const statement = findProblem(p.id)!.prompt_plain;
    for (let rep = 1; rep <= 2; rep++) {
      const checked = await checkStatement(deps, { cfg, key }, { statement, steps: p.steps, finalAnswer: p.finalAnswer });
      const cost = [checked.solve, checked.compare].reduce((sum, u) => sum + (u?.est_cost_usd ?? 0), 0);
      spent += cost;
      const accepted = solveAccepts(checked.flags);
      const row: Record<string, unknown> = {
        step: `planted:${index + 1}:${rep}`, case: p.label, why: p.why, should_accept: p.shouldAccept, accepted, correct: accepted === p.shouldAccept, checker: checked.verdict,
        checker_equivalent: checked.flags?.equivalent, checker_single_answer: checked.flags?.single_answer, first_wrong_step: checked.flags?.first_wrong_step ?? null,
        est_cost_usd: Math.round(cost * 1e6) / 1e6, providerCallsSoFar: providerCalls, spentSoFar: Math.round(spent * 1e4) / 1e4,
      };
      rows.push(row);
      appendFileSync(OUT!, JSON.stringify(row) + "\n");
      details.push({ step: row.step, case: p.label, statement_id: p.id, should_accept: p.shouldAccept, accepted, correct: row.correct, checker: checked.verdict, first_wrong_step: row.first_wrong_step, est_cost_usd: row.est_cost_usd, spent: row.spentSoFar });
      console.error(`${row.step}: ${p.shouldAccept ? "should accept" : "should reject"} -> ${accepted ? "accepted" : "rejected"} (${checked.verdict}) spent=${spent.toFixed(4)}`);
    }
  }
}

const DIAGNOSE: { id: string; reps: number; why: string }[] = [
  { id: "la-29", reps: 1, why: "rejected 2 of 2: is the written basis wrong, or is a different basis called a disagreement?" },
  { id: "la-26", reps: 1, why: "rejected 2 of 2 (and one timeout): same question for a dependence relation" },
  { id: "la-28", reps: 1, why: "rejected 2 of 2: same question for several bases at once" },
  { id: "dm-41", reps: 1, why: "an induction proof rejected 2 of 2: what does the blind solver answer for a proof?" },
  { id: "la-20", reps: 3, why: "the one case whose verdict flipped (rejected once, accepted twice): which call flipped?" },
];

async function diagnose() {
  const cfg = roleConfig("ask", ENV, "advanced");
  const key = apiKeyFor(cfg.provider, ENV)!;
  const model = deps.models.language(cfg, key);
  for (const d of DIAGNOSE) {
    const bank = findProblem(d.id)!;
    for (let rep = 1; rep <= d.reps; rep++) {
      const made = await runStructured({ model, cfg, system: solveSystem(findCourse(bank.course ?? "")), prompt: buildSolvePrompt(bank.prompt_plain), schema: SolveOutputSchema });
      if (made.kind !== "object") { details.push({ step: `diag:${d.id}:${rep}`, why: d.why, generator: made.kind }); continue; }
      const solved = await runStructured({ model, cfg, system: SOLVER_SYSTEM, prompt: buildSolverPrompt(bank.prompt_plain), schema: SolverOutputSchema });
      if (solved.kind !== "object") { details.push({ step: `diag:${d.id}:${rep}`, why: d.why, solver: solved.kind }); continue; }
      const compared = await runStructured({ model, cfg, system: COMPARER_SYSTEM, prompt: buildComparerPrompt({ statement: bank.prompt_plain, steps: made.value.steps, finalAnswer: made.value.final_answer, solverAnswer: solved.value.final_answer }), schema: ComparerOutputSchema });
      const cost = [made.usage, solved.usage, "usage" in compared ? compared.usage : undefined].reduce((sum, u) => sum + (u?.est_cost_usd ?? 0), 0);
      spent += cost;
      const flags = compared.kind === "object" ? compared.value : null;
      const row: Record<string, unknown> = { step: `diag:${d.id}:${rep}`, why: d.why, accepted: solveAccepts(flags ?? undefined), equivalent: flags?.equivalent, single_answer: flags?.single_answer, first_wrong_step: flags?.first_wrong_step ?? null, est_cost_usd: Math.round(cost * 1e6) / 1e6, spentSoFar: Math.round(spent * 1e4) / 1e4 };
      rows.push(row);
      appendFileSync(OUT!, JSON.stringify(row) + "\n");
      details.push({ ...row, bank_answer: bank.final_answer, written_steps: made.value.steps, written_answer: made.value.final_answer, blind_solver_answer: solved.value.final_answer });
      console.error(`${row.step}: accepted=${row.accepted} equivalent=${flags?.equivalent} single=${flags?.single_answer} wrong_step=${flags?.first_wrong_step} spent=${spent.toFixed(4)}`);
    }
  }
}

async function main() {
  if (SET === "diagnose") {
    await diagnose();
    writeFileSync(DETAILS!, JSON.stringify({ providerCalls, spent: Math.round(spent * 1e4) / 1e4, rows, details }, null, 1));
    console.error(`done: ${providerCalls} provider calls, about ${spent.toFixed(4)} USD estimated. Details in ${DETAILS}`);
    return;
  }
  if (SET === "wide") {
    await wide();
    writeFileSync(DETAILS!, JSON.stringify({ providerCalls, spent: Math.round(spent * 1e4) / 1e4, rows, details }, null, 1));
    console.error(`done: ${providerCalls} provider calls, about ${spent.toFixed(4)} USD estimated. Details in ${DETAILS}`);
    return;
  }
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
