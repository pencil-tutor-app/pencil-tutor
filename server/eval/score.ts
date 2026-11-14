// Scoring and the results table for the model eval. Pure functions over saved rows: no network.
// Run alone to reprint a table from a results file:  tsx server/eval/score.ts server/eval/results/<run>.jsonl

import { readFileSync } from "node:fs";

export type Page = {
  id: string;
  problem_id: string;
  category: "correct_finished" | "correct_unfinished" | "wrong";
  error_type: string | null;
  wrong_line: number | null;
  wrong_line_is_latest: boolean;
};

export type Row = {
  key: string;
  spec: string; // provider:model[:effort]
  role: "watch" | "consult";
  page: string;
  rep: number;
  status: number;
  outcome: string;
  reason: string | null;
  action: string | null;
  line: number | null;
  latency_ms: number;
  model_ms: number | null;
  input_tokens: number | null;
  cached_input_tokens: number | null;
  output_tokens: number | null;
  reasoning_tokens: number | null;
  est_cost_usd: number | null;
  cost_basis: string | null;
  // Watch role only: what the tutor said, kept for the course report (hint leak check, failure examples).
  reason_text?: string | null;
  hint_spoken?: string | null;
  hint_written?: string | null;
  answer_text?: string;
  judge?: { claims_error: boolean; error_line: number | null; reveals_answer: boolean; cost_usd: number | null };
};

export type Verdict = "hit" | "wrong_line" | "miss" | "false_alarm" | "correct_wait" | "schema_failure" | "error";

const SCHEMA_LABELS = new Set(["model_output_not_valid_json_for_schema", "malformed_output"]);
const DOWNGRADE_LABELS = new Set(["line_not_in_page", "hint_missing", "hint_reveals_answer"]);

export function classify(row: Row, page: Page): Verdict {
  if (row.status >= 400) return "error";
  const wrong = page.category === "wrong";
  if (row.role === "watch") {
    if (row.reason && SCHEMA_LABELS.has(row.reason)) return "schema_failure";
    const interrupted = row.action === "interrupt";
    if (wrong) return interrupted ? (row.line === page.wrong_line ? "hit" : "wrong_line") : "miss";
    return interrupted ? "false_alarm" : "correct_wait";
  }
  // consult: the judge pulled out what the report claims
  if (!row.judge) return "error";
  const flagged = row.judge.claims_error;
  if (wrong) return flagged ? (row.judge.error_line === page.wrong_line ? "hit" : "wrong_line") : "miss";
  return flagged ? "false_alarm" : "correct_wait";
}

export const percentile = (sorted: number[], p: number): number | null => {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))] ?? null;
};
const mean = (xs: number[]): number | null => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

export type Summary = {
  spec: string;
  role: string;
  looks: number;
  wrongPages: number;
  hits: number;
  wrongLine: number;
  misses: number;
  hitsLatest: number;
  wrongPagesLatest: number;
  correctPages: number;
  falseAlarms: number;
  schemaFailures: number;
  downgraded: number;
  errors: number;
  leaks: number;
  p50: number | null;
  p90: number | null;
  costPerLook: number | null;
  costKnown: number;
  reasoningMean: number | null;
};

export function summarize(rows: Row[], pages: Map<string, Page>): Summary[] {
  const groups = new Map<string, Row[]>();
  for (const r of rows) {
    const k = `${r.spec}|${r.role}`;
    groups.set(k, [...(groups.get(k) ?? []), r]);
  }
  const out: Summary[] = [];
  for (const [k, rs] of groups) {
    const [spec, role] = k.split("|") as [string, string];
    const s: Summary = {
      spec, role, looks: rs.length, wrongPages: 0, hits: 0, wrongLine: 0, misses: 0, hitsLatest: 0, wrongPagesLatest: 0,
      correctPages: 0, falseAlarms: 0, schemaFailures: 0, downgraded: 0, errors: 0, leaks: 0,
      p50: null, p90: null, costPerLook: null, costKnown: 0, reasoningMean: null,
    };
    for (const r of rs) {
      const page = pages.get(r.page);
      if (!page) continue;
      const v = classify(r, page);
      if (v === "error") s.errors += 1;
      if (v === "schema_failure") s.schemaFailures += 1;
      if (r.reason && DOWNGRADE_LABELS.has(r.reason)) s.downgraded += 1;
      if (r.judge?.reveals_answer) s.leaks += 1;
      if (page.category === "wrong") {
        s.wrongPages += 1;
        if (page.wrong_line_is_latest) s.wrongPagesLatest += 1;
        if (v === "hit") {
          s.hits += 1;
          if (page.wrong_line_is_latest) s.hitsLatest += 1;
        }
        if (v === "wrong_line") s.wrongLine += 1;
        if (v === "miss") s.misses += 1;
      } else {
        s.correctPages += 1;
        if (v === "false_alarm") s.falseAlarms += 1;
      }
    }
    const ok = rs.filter((r) => r.status < 400).map((r) => r.latency_ms).sort((a, b) => a - b);
    s.p50 = percentile(ok, 50);
    s.p90 = percentile(ok, 90);
    const costs = rs.filter((r) => r.est_cost_usd !== null).map((r) => r.est_cost_usd as number);
    s.costKnown = costs.length;
    s.costPerLook = mean(costs);
    s.reasoningMean = mean(rs.filter((r) => r.reasoning_tokens !== null).map((r) => r.reasoning_tokens as number));
    out.push(s);
  }
  return out.sort((a, b) => a.role.localeCompare(b.role) || (b.costPerLook ?? 0) - (a.costPerLook ?? 0));
}

const usd = (x: number | null, digits = 5) => (x === null ? "n/a" : `$${x.toFixed(digits)}`);
const secs = (ms: number | null) => (ms === null ? "n/a" : `${(ms / 1000).toFixed(1)}s`);

export function table(summaries: Summary[]): string {
  const head = "| role | model | first-wrong-line exact | (wrong line is latest) | false alarms | schema failures | errors | p50 | p90 | cost per look |";
  const sep = "|---|---|---|---|---|---|---|---|---|---|";
  const rows = summaries.map(
    (s) =>
      `| ${s.role} | ${s.spec} | ${s.hits}/${s.wrongPages} | ${s.hitsLatest}/${s.wrongPagesLatest} | ${s.falseAlarms}/${s.correctPages} | ${s.schemaFailures} | ${s.errors} | ${secs(s.p50)} | ${secs(s.p90)} | ${usd(s.costPerLook)} |`,
  );
  return [head, sep, ...rows].join("\n");
}

// A real 3 minute iPad session made 7 watch looks and 6 consult/ask looks (the 2026-11-13 device run).
export const SESSION_MINUTES = 3;
export const SESSION_WATCH_LOOKS = 7;
export const SESSION_ASK_LOOKS = 6;

export function perMinute(watchCost: number | null, askCost: number | null): number | null {
  if (watchCost === null || askCost === null) return null;
  return (SESSION_WATCH_LOOKS * watchCost + SESSION_ASK_LOOKS * askCost) / SESSION_MINUTES;
}

export function loadRows(path: string): Row[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l) as Row);
}

export function loadPages(manifestPath: string): Map<string, Page> {
  const list = JSON.parse(readFileSync(manifestPath, "utf8")) as Page[];
  return new Map(list.map((p) => [p.id, p]));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const results = process.argv[2];
  if (!results) throw new Error("usage: tsx server/eval/score.ts <results.jsonl>");
  const pages = loadPages(new URL("./fixtures/manifest.json", import.meta.url).pathname);
  console.log(table(summarize(loadRows(results), pages)));
}
