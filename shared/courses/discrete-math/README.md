# Discrete Mathematics problem bank (college track)

70 original problems for the Pencil Tutor college track, aimed at Douglas College computing-science students first, then SFU and UBC. Same record format as `shared/problems.json` (`id`, `source`, `prompt_latex`, `prompt_plain`, `prompt_parts`, `worked_solution[]`, `final_answer`, `level`), with `level: "college"` and ids `dm-01` to `dm-70`. Not wired into the app yet.

## Outline source

Douglas College, **MATH 1130 Discrete Mathematics I** (3 credits), the course the Computing Science Diploma requires.

- Course page and outline (version May 2023, current): https://douglascollege.ca/course/math-1130
- Program page listing it as a required course: https://douglascollege.ca/program/dpcpsc
- Retrieved 2026-11-14.

Course content list on that page: Logic; Methods of Proof; Set Theory; Functions; Sequences and Summation; Algorithms; Growth of Functions; Divisibility and Modular Arithmetic; Representation of Integers; Mathematical Induction; Recursion; Counting; Probability; Relations. Optional: Formal Languages, Finite State Machines.

The MATH 1130 list has no graphs or trees. Those are in the second course, **MATH 2230 Discrete Mathematics II** (https://douglascollege.ca/course/math-2230: recurrence relations, relations, graphs, trees, spanning trees), and in SFU MACM 101, so `dm-68` to `dm-70` are a small reach-ahead set, marked as such in `source`.

## Equivalent courses

| Institution | Course | URL |
| --- | --- | --- |
| SFU | MACM 101 Discrete Mathematics I (Douglas lists MATH 1130 as transferring to this) | https://www.sfu.ca/students/calendar/2026/fall/courses/macm/101.html |
| UBC Vancouver | CPSC 121 Models of Computation (CS students' discrete-math-style course) | https://vancouver.calendar.ubc.ca/course-descriptions/courses/cpscv-121-models-computation |
| UBC Vancouver | MATH 220 Mathematical Proof (induction, sets, functions, proof writing) | https://vancouver.calendar.ubc.ca/course-descriptions/courses/mathv-220-mathematical-proof |

Douglas lists the UBC transfer of MATH 1130 only as unassigned first-year MATH credit, so there is no one-to-one UBC course; CPSC 121 and MATH 220 are the closest content matches.

## Topic to ids

| Topic (MATH 1130 content item) | Ids | Count |
| --- | --- | --- |
| Logic (translation, truth tables, equivalence laws, converse/contrapositive, quantifier negation, rules of inference, invalid arguments) | dm-01 to dm-07 | 7 |
| Methods of Proof (direct, contrapositive, contradiction, cases mod 4) | dm-08 to dm-11 | 4 |
| Set Theory (cardinality, power sets, operations, subset proof, membership table, identities) | dm-12 to dm-16 | 5 |
| Functions (injective/surjective, range, composition, inverse, image/preimage, floor and ceiling) | dm-17 to dm-22 | 6 |
| Sequences and Summation (recursive to closed form, arithmetic, geometric, telescoping) | dm-23 to dm-26 | 4 |
| Algorithms and Growth of Functions (big-O witnesses, growth order, loop counting) | dm-27 to dm-30 | 4 |
| Divisibility and Modular Arithmetic (Euclid, Bezout, linear congruence, Fermat, congruence proof, CRT, division algorithm) | dm-31 to dm-37 | 7 |
| Representation of Integers (binary, hex, octal) | dm-38 to dm-39 | 2 |
| Mathematical Induction (weak, strong, inequalities, divisibility, recurrences) | dm-40 to dm-45 | 6 |
| Recursion (unrolling, characteristic equation, counting recurrence, divide and conquer) | dm-46 to dm-49 | 4 |
| Counting (product rule, repeated letters, combinations, inclusion-exclusion, pigeonhole, binomial theorem, stars and bars, derangements) | dm-50 to dm-58 | 9 |
| Probability (equiprobable sample spaces) | dm-59 to dm-61 | 3 |
| Relations (equivalence, partial order, matrix form, transitive closure) | dm-62 to dm-65 | 4 |
| Optional: Finite State Machines, Formal Languages | dm-66 to dm-67 | 2 |
| Reach-ahead (MATH 2230 / MACM 101): graphs and trees | dm-68 to dm-70 | 3 |

Within each topic the ids run roughly easy to hard. Proof problems (dm-08 to dm-11, dm-14 to dm-16, dm-22, dm-26, dm-27, dm-35, dm-40 to dm-45, dm-54) carry a model proof as `worked_solution` and a one-line statement of what was proved as `final_answer`.

Outcomes on the outline not given a dedicated problem: "find the dual of a proposition", "classify a grammar" (dm-67 notes context-free only), and "write a simple algorithm" (covered only through the loop-analysis problems).

## Licence and originality

Every problem, solution and proof here was written from scratch for this project; none is copied or adapted from a textbook, Studocu, Chegg or a past exam. The Douglas College outline was used only for the topic list. Topic coverage was cross-checked against openly licensed references (Levin, Discrete Mathematics: An Open Introduction; MIT Mathematics for Computer Science, both CC BY-SA) as topic guides only; no text was taken from them, and no NonCommercial-licensed material was used. Classic textbook statements (for example irrationality, the pigeonhole principle) appear only with freshly chosen numbers and wording.

## Verification

`verify.py` loads `problems.json` and runs one check per problem. Last run 2026-11-14: **70 of 70 pass** (52 computational, 18 proof), zero failures.

```
python3 -m pip install sympy
python3 shared/courses/discrete-math/verify.py
```

What each check does:

- Computational answers are recomputed independently and compared to `final_answer`: truth-table enumeration (logic), `itertools` brute force (sets, counting, probability, relations, spanning trees, derangements, full binary trees via recursive enumeration of all 4862 shapes), direct simulation (loops, DFA over every string up to length 12, grammar derivations), and sympy (algebra, inverses, compositions, summations, recurrences via `rsolve`, `gcdex`, `crt`, limits for growth rates). Some worked-solution lines are also compared to computed text (Euclid steps in dm-31, membership table in dm-15, base-case equalities in dm-43, matrix rows in dm-64).
- Proofs: the claim is brute-forced for small cases, the base case is evaluated, and the inductive-step or key algebraic identity is checked with sympy (for example dm-40: `rhs(m) + (m+1)(m+2) - rhs(m+1)` simplifies to 0; dm-44 reduces the step to a symbolic identity in `2^n` and `(-1)^n`; dm-45 checks the step inequality holds for every m >= 2 and fails at m = 1). This checks the computations inside each proof. It does not check the prose logic, which is human-reviewed only.
- Structure: ids contiguous, key order identical to `shared/problems.json`, `prompt_parts` mirrors `prompt_plain`, worked solutions 2 to 12 lines, `final_answer` at most 120 characters, no LaTeX leaking into plain text.
- The harness was tested by corrupting three answers in a scratch copy; all three were caught.

Not verified mechanically: the wording of the English explanations, and the intermediate lines of most worked solutions beyond the checked values above.

## Review

Teacher-quality review, 2026-11-15. All 70 problems were read, and the reasoning of every proof was read line by line rather than trusting the brute-force check: dm-01, 03, 05 to 11, 14 to 16, 22, 23, 26, 27, 35, 40 to 45, 54, 62, 63. For each, the logic was followed end to end: cases exhaustive, the inductive step really uses the hypothesis, base cases cover the start, no step assumes the conclusion. No proof had a logical error. Counting, modular-arithmetic and recurrence answers were also re-derived by hand.

| outcome | count | ids |
|---|---|---|
| reviewed | 70 | all |
| fixed | 9 | dm-04, dm-07, dm-26, dm-29, dm-32, dm-45, dm-54, dm-62, dm-66 |
| dropped | 0 | none |
| unchanged | 61 | the rest |

What was fixed: dm-54 said "any 6 numbers", which is false if repeats are allowed, now "6 different numbers"; dm-32 has many correct (s, t) pairs, now says to use back-substitution from the Euclidean algorithm so the answer is unique; dm-66 asked for a transition table but gave none, now a table line is in the solution and the final answer; dm-62 listed the transitive chains without saying chains through a pair (a, a) add nothing new; dm-29 put the question before the loop it refers to; dm-26 stated the partial-fraction split without showing it is true, now a one-line check; dm-45's reason for base cases up to n = 2 now also covers n = 0 and n = 1; dm-07 said "valid only if" where "exactly when" is meant; dm-04 had a stray "(with the original)". No numeric answer changed and `verify.py` needed no edit.

Unsure: dm-68 to dm-70 (graphs and trees) are reach-ahead material beyond the MATH 1130 outline, as the Outline source section already says. dm-15 prints four truth-table rows per solution line, which is dense for a student; left because verify.py compares that exact text.

Verification re-run 2026-11-15 with sympy 1.14.0: `verified 70/70 problems (52 computational, 18 proof) with 0 failures`.
