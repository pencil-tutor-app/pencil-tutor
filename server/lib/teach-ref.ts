import type { Env } from "./config.js";
import type { RequestCtx } from "./http.js";
import { checkProblemId, cleanProblemText, OWN_PREFIX, resolveProblem, type Problem } from "./problems.js";
import { openReference, sealKeyFor } from "./seal.js";

export type RefFailure = { ok: false; status: 422 | 503; error: string; reason: string };
export type ResolvedRequest = { ok: true; problem: Problem } | RefFailure;

// The one place watch, ask, consult, live-session and followup turn "which problem is this?" into a Problem.
//  - No problem_ref: exactly resolveProblem (a bank id, or an own problem the student typed).
//  - A problem_ref (a practice problem teach mode made): it must be sealed by this server for the same course, and for the same
//    statement when the request sends one (the statement is inside the seal, so the id and the token are enough), and not older
//    than 7 days. Then the problem is the teach problem with its checked solution and answer.
//    Anything else is 422 practice_expired and NEVER a quiet fall back to an own problem: that would lose the answer guard
//    without anyone noticing. The iPad answers it by offering a new practice problem.
// Logs: reference: accepted | rejected_<label>. Labels only, never the token or the text.
export function resolveRequestProblem(
  ctx: RequestCtx,
  env: Env,
  now: Date,
  req: { problem_id: string; problem_text?: string; problem_ref?: string },
): ResolvedRequest {
  if (!req.problem_ref) return resolveProblem(req.problem_id, req.problem_text);
  const reject = (label: string): RefFailure => {
    ctx.note({ reference: `rejected_${label}` });
    return { ok: false, status: 422, error: "practice_expired", reason: `reference_${label}` };
  };
  const unknown = checkProblemId(req.problem_id);
  if (unknown) return { ok: false, ...unknown };
  if (!req.problem_id.startsWith(OWN_PREFIX)) return reject("wrong_course");
  const key = sealKeyFor(env);
  if (!key) {
    ctx.note({ reference: "rejected_no_key" });
    return { ok: false, status: 503, error: "teach_unavailable", reason: "TEACH_SEAL_KEY is not set" };
  }
  const course = req.problem_id.slice(OWN_PREFIX.length);
  const opened = openReference(key, req.problem_ref, { course, promptPlain: req.problem_text === undefined ? undefined : cleanProblemText(req.problem_text) }, now);
  if (!opened.ok) return reject(opened.label);
  ctx.note({ reference: "accepted" });
  return {
    ok: true,
    problem: {
      id: req.problem_id,
      prompt_plain: opened.reference.prompt_plain,
      worked_solution: opened.reference.worked_solution,
      final_answer: opened.reference.final_answer,
      course,
      teach: true,
    },
  };
}
