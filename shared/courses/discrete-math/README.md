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
