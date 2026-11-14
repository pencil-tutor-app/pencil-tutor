import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

type Problem = {
  id: string;
  prompt_latex: string;
  prompt_plain: string;
  prompt_parts: ({ text: string } | { frac: { num: string; den: string } })[];
  worked_solution: string[];
  final_answer: string;
};

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
// The original twelve (BC Math 9 unit 3 equations) stay in shared/problems.json, and older app builds still send their ids.
const bank: Problem[] = JSON.parse(read("../../shared/problems.json"));

// Plain text like "−2(3 − 4x) + 5" -> a JavaScript expression with explicit multiplication.
const toJs = (s: string) =>
  s
    .replace(/−/g, "-")
    .replace(/(\d|\))\s*([a-z(])/g, "$1*$2")
    .replace(/([a-z])\(/g, "$1*(");

describe("original 12 problems (u3-..)", () => {
  it("has 12 problems with unique ids and every field", () => {
    assert.equal(bank.length, 12);
    assert.equal(new Set(bank.map((p) => p.id)).size, 12);
    for (const p of bank) {
      assert.match(p.id, /^u3-\d\d$/);
      assert.ok(p.prompt_latex && p.prompt_plain && p.final_answer && p.worked_solution.length >= 3, p.id);
      assert.ok(p.prompt_parts.length > 0, p.id);
    }
  });

  it("the final answer satisfies the prompt (both sides equal), for every problem", () => {
    for (const p of bank) {
      const [name, value] = p.final_answer.replace(/−/g, "-").split(" = ") as [string, string];
      const [left, right] = p.prompt_plain.split(" = ") as [string, string];
      const side = (expr: string) => new Function(name, `return ${toJs(expr)}`)(Number(value)) as number;
      assert.ok(Math.abs(side(left) - side(right)) < 1e-9, `${p.id}: ${p.prompt_plain} with ${p.final_answer}`);
    }
  });

  it("includes at least two fraction problems and two with a distributed negative", () => {
    const fractions = bank.filter((p) => p.prompt_parts.some((x) => "frac" in x));
    const negatives = bank.filter((p) => /(^|[=+−] ?)−\d*\(|− ?\d+\(/.test(p.prompt_plain));
    assert.ok(fractions.length >= 2, `fractions: ${fractions.length}`);
    assert.ok(negatives.length >= 2, `distributed negatives: ${negatives.length}`);
  });
});
