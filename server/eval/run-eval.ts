// Model eval for the watch and consult roles. A script, not a CI test: it makes real API calls and costs money.
//
// It drives the SAME handlers the server runs (handleWatch, handleConsult in lib/), with the real AI SDK models, so the
// prompts, the page-picture handling, the schema, the line check and the cost log are the production ones. Only the env
// changes per candidate (WATCH_MODEL / ASK_MODEL ...). Each page in fixtures/ is sent as the app sends it.
//
// Keys are read from the environment, never printed. Load them exec-only with Node's flag:
//   server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-eval.ts \
//     --models openai:gpt-6.1-sol,openai:gpt-6-luna,google:gemini-4-argon --roles watch,consult --reps 1
//
// Options: --models a,b (provider:model[:effort], effort none|low|medium|high)   --roles watch,consult
//          --reps N   --run <name>   --pages <substring filter>   --concurrency N   --budget <usd, stop when the estimate passes it>
// Results go to server/eval/results/<run>.jsonl (appended, so a rerun with the same --run resumes) and a table prints at the end.

import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { generateText, Output } from "ai";
import { z } from "zod";
import { handleConsult } from "../lib/consult.js";
import type { Env } from "../lib/config.js";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import { realModels } from "../lib/models.js";
import { estimateCostUsd } from "../lib/pricing.js";
import { findProblem } from "../lib/problems.js";
import { handleWatch } from "../lib/watch.js";
import { loadRows, perMinute, summarize, table, type Page, type Row } from "./score.js";

const HERE = new URL(".", import.meta.url).pathname;
const FIXTURES = `${HERE}fixtures/`;
const TOKEN = "eval-token";
const CONSULT_QUESTION = "Can you check my work so far? Is it right?";

type Manifest = Page & {
  file: string;
  width: number;
  height: number;
  rows: string[];
  lines: { index: number; box: { x: number; y: number; w: number; h: number } }[];
};

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

export type Spec = { provider: "openai" | "google"; model: string; effort?: string; label: string };
export function parseSpec(text: string): Spec {
  const [provider, model, effort] = text.split(":");
  if ((provider !== "openai" && provider !== "google") || !model) throw new Error(`bad model spec "${text}" (provider:model[:effort])`);
  return { provider, model, effort, label: text };
}

function envFor(spec: Spec, role: "watch" | "consult"): Env {
  const stem = role === "watch" ? "WATCH" : "ASK";
  return {
    APP_ACCESS_TOKEN: TOKEN,
    OPENAI_API_KEY: process.env.OPENAI_API_KEY,
    GEMINI_API_KEY: process.env.GEMINI_API_KEY,
    [`${stem}_PROVIDER`]: spec.provider,
    [`${stem}_MODEL`]: spec.model,
    [`${stem}_EFFORT`]: spec.effort,
  };
}

function request(path: string, body: unknown): Request {
  return new Request(`https://eval.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify(body),
  });
}

// Log lines the handlers write, keyed by request_id, so each reply can be matched to its tokens and cost.
const logsByRequest = new Map<string, Record<string, unknown>>();
setLogSink((line) => {
  const parsed = JSON.parse(line) as Record<string, unknown>;
  if (typeof parsed.request_id === "string") logsByRequest.set(parsed.request_id, parsed);
});

const JudgeSchema = z.object({
  claims_error: z.boolean(),
  error_line: z.number().int().nullable(),
  reveals_answer: z.boolean(),
});

// The judge only reads what the report CLAIMS. It is told not to decide whether the student's work is right.
const JUDGE_SYSTEM = `You read a short report that a math tutor's page reader wrote about a student's handwritten page. You do not judge the student's maths. You only extract what the report claims.

Return:
- claims_error: true if the report says any line or step the student wrote is wrong, has a mistake or a slip. false if it says the work so far is right, correct, fine or unfinished with no mistake named. A gentle suggestion to double-check a specific step as possibly wrong counts as true. A vague "keep going" does not.
- error_line: the number of the line the report says is wrong, using the numbered lines you are given (match by number said, or by the content described). If it names several, the lowest number. null if it claims no error or does not say which line.
- reveals_answer: true only if the report states the problem's CORRECT final answer (you are given it) or writes out a corrected version of a line. Reading back what the student wrote, even a wrong value, is not a leak. false otherwise.`;

async function judge(pageRows: string[], answer: string, finalAnswer: string, keys: { openai: string }): Promise<NonNullable<Row["judge"]>> {
  const model = realModels.language({ role: "ask", provider: "openai", model: "gpt-6.1-sol", level: "high_school", effort: "low" }, keys.openai);
  const numbered = pageRows.map((t, i) => `line ${i + 1}: ${t}`).join("\n");
  const result = await generateText({
    model,
    system: JUDGE_SYSTEM,
    prompt: `Lines on the student's page (as written):\n${numbered}\n\nThe problem's final answer (to detect a leak): ${finalAnswer}\n\nReport to analyse:\n${answer}`,
    output: Output.object({ schema: JudgeSchema }),
    providerOptions: { openai: { reasoningEffort: "low" } },
    maxRetries: 2,
  });
  const u = result.usage;
  const cost = u.inputTokens !== undefined && u.outputTokens !== undefined
    ? estimateCostUsd("gpt-6.1-sol", { input: u.inputTokens, cachedInput: u.inputTokenDetails.cacheReadTokens ?? 0, output: u.outputTokens }) ?? null
    : null;
  return { ...result.output, cost_usd: cost };
}

async function runOne(spec: Spec, role: "watch" | "consult", page: Manifest, rep: number, key: string): Promise<Row> {
  const png = readFileSync(`${FIXTURES}${page.file}`);
  const deps: Deps = { env: envFor(spec, role), models: realModels };
  const imageB64 = png.toString("base64");
  let res: Response;
  if (role === "watch") {
    res = await handleWatch(
      request("/api/watch", {
        session_id: `eval-${rep}`,
        problem_id: page.problem_id,
        drawing_revision: rep,
        image_png_base64: imageB64,
        image_width: page.width,
        image_height: page.height,
        lines: page.lines.map((l) => ({ ...l, last_stroke_at: "2026-11-14T00:00:00Z" })),
        history: [],
        client_time: "2026-11-14T00:00:05Z",
      }),
      deps,
    );
  } else {
    res = await handleConsult(
      request("/api/consult", {
        session_id: `eval-${rep}`,
        problem_id: page.problem_id,
        drawing_revision: rep,
        image_png_base64: imageB64,
        question: CONSULT_QUESTION,
        recent: [],
      }),
      deps,
    );
  }
  const body = (await res.json()) as Record<string, unknown>;
  const log = logsByRequest.get(String(body.request_id)) ?? {};
  const row: Row = {
    key,
    spec: spec.label,
    role,
    page: page.id,
    rep,
    status: res.status,
    outcome: String(log.outcome ?? body.error ?? ""),
    reason: typeof log.reason === "string" ? log.reason : null,
    action: typeof body.action === "string" ? body.action : null,
    line: typeof body.line === "number" ? body.line : null,
    latency_ms: Number(body.latency_ms ?? log.latency_ms ?? 0),
    model_ms: typeof log.model_ms === "number" ? log.model_ms : null,
    input_tokens: (log.input_tokens as number | null | undefined) ?? null,
    cached_input_tokens: (log.cached_input_tokens as number | null | undefined) ?? null,
    output_tokens: (log.output_tokens as number | null | undefined) ?? null,
    reasoning_tokens: (log.reasoning_tokens as number | null | undefined) ?? null,
    est_cost_usd: (log.est_cost_usd as number | null | undefined) ?? null,
    cost_basis: (log.cost_basis as string | null | undefined) ?? null,
  };
  if (role === "consult" && res.status === 200 && typeof body.answer_text === "string") {
    row.answer_text = body.answer_text;
    const problem = findProblem(page.problem_id)!;
    try {
      row.judge = await judge(page.rows, body.answer_text, problem.final_answer, { openai: process.env.OPENAI_API_KEY ?? "" });
    } catch (err) {
      console.error(`judge failed for ${key}: ${err instanceof Error ? err.name : "error"}`);
    }
  }
  return row;
}

async function pool<T>(items: T[], size: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (next < items.length) {
        const item = items[next++] as T;
        await fn(item);
      }
    }),
  );
}

async function main() {
  const specs = (arg("models") ?? "").split(",").filter(Boolean).map(parseSpec);
  if (!specs.length) throw new Error("--models is required");
  const roles = (arg("roles", "watch,consult") as string).split(",") as ("watch" | "consult")[];
  const reps = Number(arg("reps", "1"));
  const concurrency = Number(arg("concurrency", "4"));
  const budget = Number(arg("budget", "4"));
  const filter = arg("pages");
  const runName = arg("run", `run-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}`) as string;
  for (const [provider, name] of [["openai", "OPENAI_API_KEY"], ["google", "GEMINI_API_KEY"]] as const) {
    if (specs.some((s) => s.provider === provider) && !process.env[name]) throw new Error(`${name} is not set (load it with --env-file)`);
  }
  if (!process.env.OPENAI_API_KEY) throw new Error("OPENAI_API_KEY is not set (the consult judge needs it)");

  const manifest = (JSON.parse(readFileSync(`${FIXTURES}manifest.json`, "utf8")) as Manifest[]).filter((p) => !filter || p.id.includes(filter));
  const pages = new Map<string, Page>(manifest.map((p) => [p.id, p]));
  mkdirSync(`${HERE}results`, { recursive: true });
  const resultsPath = `${HERE}results/${runName}.jsonl`;
  const have = existsSync(resultsPath) ? loadRows(resultsPath) : [];
  const done = new Set(have.map((r) => r.key));
  let spent = have.reduce((a, r) => a + (r.est_cost_usd ?? 0) + (r.judge?.cost_usd ?? 0), 0);

  type Job = { spec: Spec; role: "watch" | "consult"; page: Manifest; rep: number; key: string };
  const jobs: Job[] = [];
  for (const spec of specs) for (const role of roles) for (const page of manifest) for (let rep = 1; rep <= reps; rep++) {
    const key = `${spec.label}|${role}|${page.id}|${rep}`;
    if (!done.has(key)) jobs.push({ spec, role, page, rep, key });
  }
  console.error(`run ${runName}: ${jobs.length} calls to make (${done.size} already saved), estimated spend so far $${spent.toFixed(3)}`);

  let stopped = false;
  await pool(jobs, concurrency, async (job) => {
    if (stopped) return;
    if (spent > budget) {
      stopped = true;
      console.error(`budget $${budget} reached (estimated $${spent.toFixed(3)}); stopping`);
      return;
    }
    const row = await runOne(job.spec, job.role, job.page, job.rep, job.key);
    spent += (row.est_cost_usd ?? 0) + (row.judge?.cost_usd ?? 0);
    appendFileSync(resultsPath, JSON.stringify(row) + "\n");
  });

  const rows = loadRows(resultsPath);
  const summaries = summarize(rows, pages);
  const markdown = table(summaries);
  console.log(markdown);
  const judgeCost = rows.reduce((a, r) => a + (r.judge?.cost_usd ?? 0), 0);
  const modelCost = rows.reduce((a, r) => a + (r.est_cost_usd ?? 0), 0);
  console.log(`\nestimated spend: models $${modelCost.toFixed(3)} + judge $${judgeCost.toFixed(3)} = $${(modelCost + judgeCost).toFixed(3)}`);
  // Cost per minute of a real session (7 watch looks + 6 consult/ask looks in 3 minutes) for each model used in both roles.
  for (const spec of specs) {
    const w = summaries.find((s) => s.spec === spec.label && s.role === "watch");
    const c = summaries.find((s) => s.spec === spec.label && s.role === "consult");
    if (w && c) console.log(`${spec.label}: ${perMinute(w.costPerLook, c.costPerLook)?.toFixed(5) ?? "n/a"} USD per minute (watch+consult only, not the voice)`);
  }
  writeFileSync(`${HERE}results/${runName}.md`, `${markdown}\n`);
}

main().catch((err) => {
  console.error(err instanceof Error ? `${err.name}: ${err.message}` : "eval failed");
  process.exit(1);
});
