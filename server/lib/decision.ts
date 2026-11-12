import { WatchDecisionSchema, type HistoryEntry, type PageLine } from "./policy.js";
import type { Problem } from "./problems.js";

export type WatchResult = {
  action: "wait" | "interrupt";
  line: number | null;
  reason: string;
  hint_spoken: string | null;
  hint_written: string | null;
  // A short label for the log (never content): why this result came out.
  label: string;
};

const wait = (label: string, reason: string): WatchResult => ({
  action: "wait",
  line: null,
  reason,
  hint_spoken: null,
  hint_written: null,
  label,
});

const squash = (s: string) => s.toLowerCase().replace(/[−–]/g, "-").replace(/\s+/g, "");

// Validates what the model said. Anything unusable becomes a wait with a labelled reason; this never throws.
export function finalizeDecision(raw: unknown, lines: PageLine[], problem: Problem): WatchResult {
  const parsed = WatchDecisionSchema.safeParse(raw);
  if (!parsed.success) return wait("malformed_output", "The model answer did not match the schema, so waiting.");
  const d = parsed.data;
  if (d.action === "wait") {
    return { action: "wait", line: null, reason: d.reason, hint_spoken: null, hint_written: null, label: "model_wait" };
  }
  if (d.line === null || !lines.some((l) => l.index === d.line)) {
    return wait("line_not_in_page", "The model named a line that is not on the page, so waiting.");
  }
  const spoken = d.hint_spoken?.trim();
  const written = d.hint_written?.trim();
  if (!spoken || !written) return wait("hint_missing", "The model interrupted without a hint, so waiting.");
  if (squash(`${spoken} ${written}`).includes(squash(problem.final_answer))) {
    return wait("hint_reveals_answer", "The hint contained the final answer, so waiting.");
  }
  return { action: "interrupt", line: d.line, reason: d.reason, hint_spoken: spoken, hint_written: written, label: "model_interrupt" };
}

// ---------------------------------------------------------------- scripted mode (tests only)

export const SCRIPTED_PLANTED_PROBLEM = "u3-04";
export const SCRIPTED_PLANTED_LINE = 2;

// Fixed script: problem u3-04 interrupts once on line 2 (when the page has a line 2 and the history holds no
// earlier interrupt on it); every other problem, and every later look, waits.
export function scriptedWatch(problemId: string, lines: PageLine[], history: HistoryEntry[]): WatchResult {
  const alreadyDone = history.some((h) => h.action === "interrupt" && h.line === SCRIPTED_PLANTED_LINE);
  const hasLine = lines.some((l) => l.index === SCRIPTED_PLANTED_LINE);
  if (problemId === SCRIPTED_PLANTED_PROBLEM && hasLine && !alreadyDone) {
    return {
      action: "interrupt",
      line: SCRIPTED_PLANTED_LINE,
      reason: "scripted planted mistake",
      hint_spoken: "Take another look at this line. Check the sign when the minus multiplies the bracket.",
      hint_written: "Check the signs here",
      label: "scripted_interrupt",
    };
  }
  return wait("scripted_wait", "scripted: nothing to say");
}

export const SCRIPTED_TRANSCRIPT = "scripted question";
export const SCRIPTED_ANSWER = "This is a scripted answer. Look at your last line and tell me what you did to both sides.";
