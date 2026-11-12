import problemData from "../data/problems.json" with { type: "json" };

export type Problem = {
  id: string;
  prompt_plain: string;
  worked_solution: string[];
  final_answer: string;
};

// server/data/problems.json is a copy of shared/problems.json (the folder `vercel deploy` uploads is server/).
// A test fails if the two drift apart; refresh with `npm run sync-problems`.
const problems: Problem[] = problemData;
const byId = new Map(problems.map((p) => [p.id, p]));

export const problemCount = problems.length;
export const findProblem = (id: string): Problem | undefined => byId.get(id);
