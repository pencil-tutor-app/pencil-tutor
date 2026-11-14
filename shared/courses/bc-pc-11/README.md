# BC Pre-calculus 11: original problem bank for Pencil Tutor

118 original problems in the `shared/problems.json` format (level `high_school`, ids `pc11-01` to `pc11-118`). Each is worked by hand on a page in 3 to 7 written lines (most 4) with clean numbers. Files in this folder: `problems.json`, `verify.py`, this README.

## Official curriculum
- Source (fetched 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/11/pre-calculus
- Course PDF: https://curriculum.gov.bc.ca/sites/curriculum.gov.bc.ca/files/curriculum/mathematics/en_mathematics_11_pre-calculus.pdf
- Elaborations PDF: https://curriculum.gov.bc.ca/sites/curriculum.gov.bc.ca/files/curriculum/mathematics/en_mathematics_11_pre-calculus_elab.pdf
- Content standards, as published (Content section of the page above):

```
real number system
- classification

powers with rational exponents
- positive and negative rational exponents
- exponent laws
- evaluation using order of operations
- numerical and variable bases

radical operations and equations
- simplifying radicals
- ordering a set of irrational numbers
- performing operations with radicals
- solving simple (one radical only) equations algebraically and graphically
- identifying domain restrictions and extraneous roots of radical equations

polynomial factoring
- greatest common factor of a polynomial
- trinomials of the form ax² + bx + c
- difference of squares of the form a²x² − b²y²
- may extend to a(f(x))² + b(f(x)) + c, a²(f(x))² − b²(f(x))²

rational expressions and equations
- simplifying and applying operations to rational expressions
- identifying non-permissible values
- solving equations and identifying any extraneous roots

quadratic functions and equations
- identifying characteristics of graphs (including domain and range, intercepts, vertex, symmetry), multiple forms, function notation, extrema
- exploring transformations
- solving equations (e.g., factoring, quadratic formula, completing the square, graphing, square root method)
- connecting equation-solving strategies
- connecting equations with functions
- solving problems in context

linear and quadratic inequalities
- single variable (e.g., 3x − 7 ≤ −4, x² − 5x + 6 > 0)
- domain and range restrictions from problems in situational contexts
- sign analysis: identifying intervals where a function is positive, negative, or zero
- symbolic notation for inequality statements, including interval notation

trigonometry: non-right triangles and angles in standard position
- use of sine and cosine laws to solve non-right triangles, including ambiguous cases
- contextual and non-contextual problems
- angles in standard position: degrees; special angles, as connected with the 30-60-90 and 45-45-90 triangles
- unit circle
- reference and coterminal angles
- terminal arm
- trigonometric ratios
- simple trigonometric equations

financial literacy: compound interest, investments, loans
- compound interest
- introduction to investments/loans with regular payments, using technology
- buy/lease
```

## Standard to problem ids

| Content standard (topic group) | Problems | Ids |
|---|---|---|
| real number system (classification) | 5 | pc11-01 to pc11-05 |
| powers with rational exponents | 8 | pc11-06 to pc11-13 |
| radical operations (simplifying, ordering, operations) | 8 | pc11-14 to pc11-21 |
| radical equations (algebraic and graphical, domain, extraneous roots) | 8 | pc11-22 to pc11-29 |
| polynomial factoring | 12 | pc11-30 to pc11-41 |
| rational expressions and equations | 10 | pc11-42 to pc11-51 |
| quadratic functions: characteristics of graphs (vertex, intercepts, domain and range, extrema) | 7 | pc11-52 to pc11-58 |
| quadratic functions: exploring transformations | 4 | pc11-59 to pc11-62 |
| quadratic equations: solving (factoring, quadratic formula, completing the square, square root method) | 8 | pc11-63 to pc11-70 |
| quadratic equations and functions: solving problems in context | 6 | pc11-71 to pc11-76 |
| linear and quadratic inequalities (single variable, interval notation, sign analysis, restrictions) | 10 | pc11-77 to pc11-86 |
| trigonometry: angles in standard position, reference and coterminal angles, terminal arm | 6 | pc11-87 to pc11-92 |
| trigonometry: unit circle | 4 | pc11-93 to pc11-96 |
| trigonometry: simple trigonometric equations | 5 | pc11-97 to pc11-101 |
| trigonometry: sine law and cosine law (non-right triangles, ambiguous case, contextual problems) | 9 | pc11-102 to pc11-110 |
| financial literacy: compound interest, investments and loans, buy/lease | 8 | pc11-111 to pc11-118 |

## Standards not set as written work, or set differently
- Curricular Competencies (reasoning, communicating, First Peoples perspectives, "develop thinking strategies to solve puzzles and play games"): these are ways of working, not computable content, so no problems. They are exercised inside every worked solution rather than as separate items.
- Anything that needs a drawn graph as the prompt (sketching parabolas, reading a graph): the prompt format is text and stacked fractions only. Graph-based standards ("identifying characteristics of graphs", "exploring transformations", "solving ... graphically") are set as equation and description tasks (vertex form, intercepts, transformation lists, intersection of two curves). The student sketches by hand if they wish; the checked answer is numeric or verbal.
- "Introduction to investments/loans with regular payments, using technology": done with the standard annuity and loan formulas and a calculator, not a spreadsheet or finance app.


## Closest Ontario and Alberta courses

Ontario:
- Closest course: **Functions, Grade 11, University Preparation (MCR3U)**. Official ministry document (2007, the version our fetch returned): https://www.edu.gov.on.ca/eng/curriculum/secondary/math1112currb.pdf . Course page: https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses/mcr3u (the page text did not load in our fetch, so the course page itself is unverified; the PDF is what was read). Strands read from the PDF: Characteristics of Functions, Exponential Functions, Discrete Functions, Trigonometric Functions. Second closest: **Functions and Applications, Grade 11, University/College (MCF3M)** (same PDF).
- Overlap: quadratic functions and equations (vertex, intercepts, completing the square, factoring), compound interest (Discrete Functions strand), sine law and cosine law, angles 0-360 and the unit circle, some work with radical and rational expressions.
- Main differences (keyword counts inside the MCR3U section of the PDF, so treat as indicative, unverified beyond that): MCR3U treats functions first (domain and range, inverses, transformations y = af(k(x − d)) + c, exponential functions, sequences and series) and has no linear or quadratic inequalities (0 hits for "inequalit"). BC Pre-calc 11 puts radicals, rational exponents, rational expressions and equations, factoring and inequalities up front and has no exponential-function or sequence/series strand (BC places those in Pre-calculus 12; not checked here). Ambiguous case: 1 hit in MCR3U (so briefly present), full emphasis in BC. MCF3M has no radical or rational-expression content (0 hits).
- Status caveat: Ontario has been revising secondary mathematics since the Grade 9 de-streaming. The 2007 document may no longer be the current Grade 11 text. Unverified.

Alberta:
- Closest course: **Mathematics 20-1** (Program of Studies, 2008). Official page (read in full): https://curriculum.learnalberta.ca/curriculum/en/pos/MAT_HS/MAT2791 . Outcomes with assessment standards PDF seen in search results (not opened): https://open.alberta.ca/dataset/764262ca-65e0-47fa-830b-7118499fb9ee/resource/e3e47dc0-4620-468f-a5a0-7e8545cea334/download/mathematics20-1.pdf
- Overlap (verified from the outcome list): operations on radicals and radical equations (square roots only), rational expressions (equivalent forms, operations, equations), angles in standard position 0°-360°, primary trig ratios, sine and cosine law including the ambiguous case, factoring ax² + bx + c and difference of squares, analysing quadratic functions in vertex and standard form, quadratic equations, quadratic inequalities in one variable.
- Alberta 20-1 adds (not in BC Pre-calc 11): absolute value (numbers and functions), systems of linear-quadratic and quadratic-quadratic equations, inequalities in two variables, arithmetic and geometric sequences and series, reciprocal functions.
- BC Pre-calc 11 adds (not in the Alberta 20-1 outcome list as fetched): powers with rational exponents, classification of the real number system and ordering irrational numbers, financial literacy (compound interest, loans, buy/lease), unit circle and special angles as a named topic.
- Status caveat: Alberta has been replacing older curricula; whether the 2008 grades 10-12 mathematics program is still the current one was not checked. Unverified.

## Originality
Every prompt, number set, context and worked solution was written for this bank. Nothing was copied or adapted from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math and similar), from Studocu or Chegg, or from provincial exams, and no NonCommercial-licensed material was used. Only the official curriculum documents cited in this README were read, for the lists of standards and outcomes. Textbook-staple scenarios (a ball thrown upward, fencing along a river, a tower seen from two points) are generic textbook-genre situations with numbers chosen fresh. No student name appears anywhere.

## Verification (run 2026-11-14; re-run with `python3 -I verify.py`, needs `sympy`)
`verify.py` is both the source and the checker: it holds every problem together with a check function, regenerates the expected `problems.json`, fails if the file on disk differs (`--write` rewrites it), and exits non-zero on any failure.
- Per-problem check: each final answer is recomputed independently with sympy (solving, factoring and expanding, calculus for vertices), `fractions`/`math`/`statistics` (money, trigonometry, normal distribution), or brute force (primality, the counting game, corner-point optimization, table search), then compared with the text of `final_answer`. Where a result has more than one required part (all roots, all corner points, every angle) each part is asserted.
- Automatic line checks on every worked solution: pure-number chains such as `2(5) − 4 = 6` are evaluated, and for equation problems every line that contains only the variable is substituted with the known roots.
- Intermediate values: rounding steps (powers such as `(1.005)^60 ≈ 1.34885`, trig values) are checked as strings against the computed numbers.
- Mutation test: wrong answers deliberately injected into a copy of `verify.py` (changed roots, factors, dollar amounts, an arithmetic step, a corner point) were all caught.
- Not mechanically verified: free-text explanations in worked-solution lines (the check confirms numbers and key phrases, not that every sentence is well phrased), and the wording of word problems. Lines that mix words and algebra are only covered by the equation and chain checks where they parse.

## Format notes
- `prompt_parts` uses only `text` and `frac` parts, as in `shared/problems.json`. Powers are Unicode superscripts (x², x⁴) or `^(a/b)` for rational exponents; radicals are √ and ∛ and ∜. Word problems keep the prose in `prompt_plain` and `prompt_latex` (the LaTeX field is a mechanical conversion of the plain text, with prose left as prose).
- Angles in trigonometry answers are in degrees, to the nearest tenth where a calculator is needed.
- Money answers are rounded to the cent; intermediate decimals in the worked solution are shown to five places so the student can follow the rounding.


## Review (teacher-quality pass, 2026-11-15)
Every one of the 118 problems was read as a teacher would: one intended answer (units, rounding, form stated), age-appropriate wording, fit with BC Pre-calculus 11, one step per worked line with no skipped steps, final answer matching the request, difficulty ramp inside each standard, no duplicated problems, no names, no recognisable textbook or exam items. `verify.py` was updated for every change and `python3 -I verify.py` passes (118/118).

- Counts: 118 reviewed, 10 fixed, 0 dropped, 108 unchanged. Ids are unchanged.
- Fixed: pc11-17 (worked solution never stated the conclusion), pc11-29 (the context was vague about dropping from rest), pc11-46 and pc11-47 (worked solution ended at the non-permissible values without writing the combined fraction), pc11-55 (answer gave a y-intercept the prompt never asked for), pc11-72 (money written as "$12 800" and "$12800"; now "$12,800" everywhere), pc11-85 (reused the profit function of pc11-76; now a different function, answer $10 to $20), pc11-87 ("one positive and one negative coterminal angle" has many correct answers; now asks for +360° and −360°), pc11-108 (the classic 3-5-7 triangle, and the same answer 7 as pc11-106; now 6 km and 10 km, answer 14 km), pc11-113 (needed logarithms, which are Pre-calculus 12; now a calculator trial-and-error to the smallest whole number of years, 10).
- Most common problem: a prompt that allowed more than one correct answer or asked for less than the answer gave (pc11-55, pc11-87, pc11-113), followed by worked solutions that stop before stating the result (pc11-17, 46, 47).
- Unsure: pc11-38 says x^2 + 9 "does not factor over the real numbers", fine for this course but a Pre-calculus 11 teacher may prefer "over the integers". pc11-110 ignores the observer eye height (stated as level ground only). Both left as they are.
