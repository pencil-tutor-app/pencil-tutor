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
};

// server/data/problems.json is built from shared/ by `npm run build-courses` (the folder `vercel deploy` uploads is server/).
// A test fails if it is stale, has a duplicate id, or a course folder is missing from it.
const bank = bankData as { courses: Course[]; problems: Problem[] };
const byId = new Map(bank.problems.map((p) => [p.id, p]));
const coursesBySlug = new Map(bank.courses.map((c) => [c.slug, c]));

export const problemCount = bank.problems.length;
export const courseCount = bank.courses.length;
export const findProblem = (id: string): Problem | undefined => byId.get(id);
export const courseOf = (problem: Problem): Course | undefined => (problem.course ? coursesBySlug.get(problem.course) : undefined);
// The model tier for a problem: advanced when its course's tier is advanced or the problem itself says so; standard otherwise.
export const levelFor = (problem: Problem, course: Course | undefined): Level =>
  course?.tier === "advanced" ? "advanced" : parseLevel(problem.level);
export const levelOf = (problem: Problem): Level => levelFor(problem, courseOf(problem));
export const tierOf = (problem: Problem): "standard" | "advanced" => (levelOf(problem) === "advanced" ? "advanced" : "standard");

// One line when the function starts, so a deploy that lost or kept a course shows up in the logs.
logLine("info", { event: "bank_loaded", courses: courseCount, problems: problemCount });
