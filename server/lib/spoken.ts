import type { Problem } from "./problems.js";

// What a spoken or written answer looks like once number words and spoken operators are turned into symbols, so "x equals four"
// and "x = 4" are the same text. Used only to decide whether a tutor answer states the final answer of a teach (practice) problem.
// Number words zero to twenty, the tens and "twenty one" style compounds; the spoken operators equals, is, minus, negative, plus,
// times, over, divided by, squared, cubed, "to the fourth", "to the power of", prime, point; brackets and commas are ignored.
// It errs toward withholding: a false match hides a harmless sentence, a miss shows the answer.
// The real model said "y prime equals twenty-four x times open parenthesis three x squared minus two close parenthesis cubed" and,
// asked again, "... times the quantity three x squared minus two, cubed" (docs/evals/2026-11-28-teach-flow.md); both are tests.

const ONES: Record<string, number> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19, twenty: 20,
};
const TENS: Record<string, number> = { twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90 };
const ORDINALS: Record<string, number> = { second: 2, third: 3, fourth: 4, fifth: 5, sixth: 6, seventh: 7, eighth: 8, ninth: 9, tenth: 10 };

const OPERATORS: [RegExp, string | ((match: string, word: string) => string)][] = [
  [/\bis equal to\b|\bequal to\b|\bequals\b|\bequal\b|\bis\b/g, " = "],
  [/\b(?:open|opening|left|close|closing|closed|right)\s+(?:parenthesis|parentheses|paren|bracket|brace)\b|\b(?:the )?quantity\b/g, " "],
  [/\bprime\b/g, "' "],
  [/\bpoint\b/g, " . "],
  [/\bto the power of\b/g, " ^ "],
  [new RegExp(`\\bto the (${Object.keys(ORDINALS).join("|")})(?: power)?\\b`, "g"), (_match, word) => ` ^${ORDINALS[word] ?? ""} `],
  [/\bdivided by\b|\bover\b/g, " / "],
  [/\bmultiplied by\b|\btimes\b/g, " * "],
  [/\bminus\b|\bnegative\b/g, " - "],
  [/\bplus\b/g, " + "],
  [/\bsquared\b/g, " ^2 "],
  [/\bcubed\b/g, " ^3 "],
];

function numberWords(text: string): string {
  const tens = Object.keys(TENS).join("|");
  const ones = Object.keys(ONES).filter((w) => w !== "zero" && (ONES[w] ?? 99) < 10).join("|");
  const compound = new RegExp(`\\b(${tens})[ -](${ones})\\b`, "g");
  const plain = new RegExp(`\\b(${[...Object.keys(ONES), ...Object.keys(TENS)].join("|")})\\b`, "g");
  return text
    .replace(compound, (_, t: string, o: string) => String((TENS[t] ?? 0) + (ONES[o] ?? 0)))
    .replace(plain, (w: string) => String(ONES[w] ?? TENS[w] ?? w));
}

// Lower case, one minus sign, operators and number words as symbols, spaces kept.
function normalizeSpoken(text: string): string {
  let t = text.toLowerCase().replace(/[−–—]/g, "-").replace(/[×·]/g, "*").replace(/÷/g, "/");
  for (const [pattern, symbol] of OPERATORS) t = t.replace(pattern, symbol as string);
  // Brackets and commas carry grouping that speech says in many ways ("open parenthesis", "the quantity ..., cubed"), so none of
  // them is kept, on either side of the comparison: the digits, letters and operators in order are what is compared.
  return numberWords(t).replace(/[()[\]{},]/g, " ");
}

// The same with every space removed, so "x = 4", "x=4" and "x equals four" are one string.
export const spokenForm = (text: string): string => normalizeSpoken(text).replace(/\s+/g, "");

// A model writes "y' = 12(2x - 5)^5." with a full stop: the answer is the same without it, and the tutor's sentence may not have one.
export const stripSentenceEnd = (answer: string): string => answer.replace(/[\s.,;:!?]+$/, "");

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The answer as a pattern over the spaced text: its characters in order with any spaces and an optional times sign between them
// ("24x(3x^2-2)^3" is also "24 x times open parenthesis ..."), not glued to a longer word or number on either side
// ("2x = 4" is not the answer "x = 4"; "x = 45" and "x = 4.5" are not "x = 4").
function answerPattern(answer: string): RegExp {
  const body = [...answer.replace(/\*/g, "")].map(escapeRegExp).join("\\s*\\*?\\s*");
  const before = /^[a-z0-9]/.test(answer) ? "(?<![a-z0-9.])" : "";
  const after = /[0-9]$/.test(answer) ? "(?![0-9a-z]|\\.[0-9])" : /[a-z]$/.test(answer) ? "(?![a-z0-9])" : "";
  return new RegExp(before + body + after);
}

// True when the text states the final answer, written or spoken. Two ways: the whole answer ("x = 4" inside "x equals four"),
// or the answer's value right behind an equals sign ("the answer is four" for "x = 4") when nothing continues the number or the
// expression after it ("= 45", "= 4.5", "= 4x" and "= 4 - 1" do not count).
export function revealsAnswerSpoken(text: string, finalAnswer: string): boolean {
  const answer = spokenForm(stripSentenceEnd(finalAnswer));
  if (answer === "") return false;
  const spoken = normalizeSpoken(text);
  if (answerPattern(answer).test(spoken)) return true;
  const value = answer.split("=").at(-1) ?? "";
  if (value === "" || value === answer) return false;
  return new RegExp(`=\\s*${answerPattern(value).source}(?!\\s*[-+*/^=])`).test(spoken);
}

export const ANSWER_WITHHELD_TEXT = "Give it a try on the page first. I'll check each line as you write.";

export const leaksAnswer = (text: string, problem: Problem): boolean =>
  problem.teach ? revealsAnswerSpoken(text, problem.final_answer) : false;

// For a teach problem an answer that states the final answer is replaced; every other problem passes through untouched.
export function guardSpokenAnswer(problem: Problem, text: string): { text: string; withheld: boolean } {
  return problem.teach && revealsAnswerSpoken(text, problem.final_answer) ? { text: ANSWER_WITHHELD_TEXT, withheld: true } : { text, withheld: false };
}
