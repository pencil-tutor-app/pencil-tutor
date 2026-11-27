import bankData from "../data/problems.json" with { type: "json" };
import { logLine } from "./log.js";
import { parseLevel, type Level } from "./config.js";

export type CourseGroup = "elementary" | "high_school" | "college";

// A course, as the tutor prompts need it: which course the problem is from and how old the student is.
export type Course = {
  slug: string;
  title: string;
  group: CourseGroup;
  grade: number | null;
  level: string;
  // Which model tier tutors the course: "standard" (cheap model, the default) or "advanced" (frontier model, about ten times
  // the cost per look). Set in the course's course.json; escalation needs measured handwriting results first.
  tier: "standard" | "advanced";
};

export type Problem = {
  id: string;
  prompt_plain: string;
  worked_solution: string[];
  final_answer: string;
  // Slug of the course the problem belongs to. Missing means the original BC Math 9 behaviour (no course line in prompts).
  course?: string;
  // Per-problem difficulty. Only "advanced" matters to the model choice (the bank's own words, such as college, do not).
  level?: string;
  // True for a problem the student typed on the iPad ("own:<course>"): there is no worked solution and no final answer.
  own?: true;
};

// server/data/problems.json is built from shared/ by `npm run build-courses` (the folder `vercel deploy` uploads is server/).
// A test fails if it is stale, has a duplicate id, or a course folder is missing from it.
const bank = bankData as { courses: Course[]; problems: Problem[] };
const byId = new Map(bank.problems.map((p) => [p.id, p]));
const coursesBySlug = new Map(bank.courses.map((c) => [c.slug, c]));

export const problemCount = bank.problems.length;
export const courseCount = bank.courses.length;
export const findProblem = (id: string): Problem | undefined => byId.get(id);

// Own problems: the student types the statement, the app sends the id "own:<course slug>" and the typed text with every
// request that reaches a model. There is no answer key, so the prompts say so (policy.ts referenceBlock) and the answer-leak
// checks skip an empty final_answer (decision.ts revealsAnswer).
export const OWN_PREFIX = "own:";
export const OWN_TEXT_MAX_CHARS = 500;
// Which model tier tutors an own problem: advanced (gpt-6.1-sol unless WATCH_MODEL_ADVANCED / ASK_MODEL_ADVANCED say otherwise).
// Chosen by the no-reference eval, docs/evals/2026-11-28-no-reference-eval.md: the same false alarms as gpt-6-luna, more mistakes caught.
export const OWN_PROBLEM_LEVEL: Level = "advanced";

export type ProblemFailure = { status: 422; error: "unknown_problem" | "unknown_course" | "invalid_request"; reason: string };
export type ResolvedProblem = { ok: true; problem: Problem } | ({ ok: false } & ProblemFailure);

const unknownCourse: ProblemFailure = { status: 422, error: "unknown_course", reason: "own problem course is not in the bank" };
const unknownProblem: ProblemFailure = { status: 422, error: "unknown_problem", reason: "problem_id is not in the bank" };

// Heartbeat only meters time, so it checks the id and ignores any text.
export function checkProblemId(id: string): ProblemFailure | undefined {
  if (id.startsWith(OWN_PREFIX)) return coursesBySlug.has(id.slice(OWN_PREFIX.length)) ? undefined : unknownCourse;
  return byId.has(id) ? undefined : unknownProblem;
}

// A bank id resolves as before (any problem_text is ignored: the bank's wording wins). "own:<slug>" needs a known course and
// problem_text of 1 to 500 characters once trimmed; line breaks and runs of spaces become one space so the typed text stays
// one line of the prompt.
export function resolveProblem(id: string, problemText?: string): ResolvedProblem {
  if (!id.startsWith(OWN_PREFIX)) {
    const problem = byId.get(id);
    return problem ? { ok: true, problem } : { ok: false, ...unknownProblem };
  }
  const slug = id.slice(OWN_PREFIX.length);
  if (!coursesBySlug.has(slug)) return { ok: false, ...unknownCourse };
  const text = problemText?.replace(/\s+/g, " ").trim() ?? "";
  if (text.length < 1 || text.length > OWN_TEXT_MAX_CHARS) {
    return { ok: false, status: 422, error: "invalid_request", reason: `problem_text: an own problem needs 1 to ${OWN_TEXT_MAX_CHARS} characters` };
  }
  return { ok: true, problem: { id, prompt_plain: text, worked_solution: [], final_answer: "", course: slug, level: OWN_PROBLEM_LEVEL, own: true } };
}
export const courseOf = (problem: Problem): Course | undefined => (problem.course ? coursesBySlug.get(problem.course) : undefined);
// The model tier for a problem: advanced when its course's tier is advanced or the problem itself says so; standard otherwise.
export const levelFor = (problem: Problem, course: Course | undefined): Level =>
  course?.tier === "advanced" ? "advanced" : parseLevel(problem.level);
export const levelOf = (problem: Problem): Level => levelFor(problem, courseOf(problem));
export const tierOf = (problem: Problem): "standard" | "advanced" => (levelOf(problem) === "advanced" ? "advanced" : "standard");

// The same four facts on every model endpoint's log line: what kind of problem, its course, the tier, and for an own problem
// how long the typed text is (a count, never the text).
export const problemFields = (problem: Problem): Record<string, string | number> => ({
  problem_kind: problem.own ? "own" : "bank",
  course: problem.course ?? "none",
  tier: tierOf(problem),
  ...(problem.own ? { problem_text_chars: problem.prompt_plain.length } : {}),
});

// One line when the function starts, so a deploy that lost or kept a course shows up in the logs.
logLine("info", { event: "bank_loaded", courses: courseCount, problems: problemCount });
