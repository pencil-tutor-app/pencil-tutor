import problemData from "../data/problems.json" with { type: "json" };
import { parseLevel, type Level } from "./config.js";

export type Problem = {
  id: string;
  prompt_plain: string;
  worked_solution: string[];
  final_answer: string;
  // Difficulty. Missing means high_school. "advanced" (college level and harder) runs on the frontier model.
  level?: Level;
};

// server/data/problems.json is a copy of shared/problems.json (the folder `vercel deploy` uploads is server/).
// A test fails if the two drift apart; refresh with `npm run sync-problems`.
const problems = problemData as Problem[];
const byId = new Map(problems.map((p) => [p.id, p]));

export const problemCount = problems.length;
export const findProblem = (id: string): Problem | undefined => byId.get(id);
export const levelOf = (problem: Problem): Level => parseLevel(problem.level);
