# Calculus I problem bank (college track)

70 original differential-calculus problems for Pencil Tutor, aimed at Douglas College MATH 1120 first, then SFU and UBC. Not wired into the app yet.

## Files

| file | what |
|---|---|
| `problems.json` | the bank, same shape as `shared/problems.json` (`id`, `source`, `prompt_latex`, `prompt_plain`, `prompt_parts`, `worked_solution`, `final_answer`, `level`). Ids `c1-01` to `c1-70`, `level` is `"college"`, `source` is the topic plus `, original`. |
| `verify.py` | sympy check of every problem (see Verification). |
| `README.md` | this file. |

`prompt_parts` follows `server/README.md`: `text` items and stacked `frac` items on one row, fractions never nested. Calculus prompts are written as one line, for example `lim(x→−3) (x² + 5x + 6)/(x² − 9)`, with `x→a` limits written inline and limit direction as `5⁻` / `5⁺`. Seven word-problem prompts (optimization, related rates, motion) run past 140 characters, the longest 223; the iPad row will need to wrap them.

## Course outline used

Douglas College **MATH 1120 Calculus I** (3 credits, course guideline dated May 2026, current).
URL: https://douglascollege.ca/course/math-1120

Outline topics (from the page's "Course content") and the ids that cover them:

| outline topic | ids |
|---|---|
| Limits: intuitive notion, limit laws (algebraic, one-sided) | c1-01 to c1-04 |
| Limits: Squeeze Theorem | c1-05, c1-06 |
| Limits at infinity, horizontal asymptotes | c1-07 to c1-09 |
| Infinite limits, vertical asymptotes | c1-10 to c1-12 |
| Continuity: definition, jump / removable / infinite discontinuities, continuity on an interval | c1-13 to c1-16 |
| Intermediate Value Theorem | c1-17, c1-18 |
| Derivative from the definition, rates of change, tangent lines | c1-19 to c1-22 |
| Product and quotient rules | c1-23, c1-24 |
| Polynomial, root, rational, exponential, trig, inverse trig, log derivatives | c1-25 to c1-28 |
| Chain rule | c1-29 to c1-31 |
| Logarithmic differentiation | c1-32, c1-33 |
| Higher derivatives | c1-34 |
| Implicit differentiation | c1-35 to c1-37 |
| Mean Value Theorem | c1-38, c1-39 |
| Behaviour of functions: increase/decrease, concavity, inflection, local and global extrema, asymptotes, curve sketching | c1-40 to c1-44 |
| L'Hôpital's Rule | c1-45 to c1-47 |
| Newton's Method | c1-48, c1-49 |
| Optimization | c1-50 to c1-53 |
| Differentials and linear approximation | c1-54 to c1-56 |
| Related rates | c1-57 to c1-60 |
| Applications to physical sciences (velocity, acceleration) and the notion of an antiderivative | c1-61, c1-62 |
| Parametrically defined curves | c1-63 to c1-65 |
| Curves in polar coordinates | c1-66, c1-67 |
| Antiderivatives and basic antidifferentiation formulas | c1-68 to c1-70 |

Every bullet in the outline's content list has at least one problem. The outline's wording was used only to choose topics.

## Same course elsewhere

| school | code and title | URL |
|---|---|---|
| SFU | MATH 151 Calculus I | https://www.sfu.ca/students/calendar/2026/spring/courses/math/151.html |
| UBC Vancouver | MATH_V 100 Differential Calculus with Applications | https://vancouver.calendar.ubc.ca/course-descriptions/courses/mathv-100 |

Douglas's own transfer table on the MATH 1120 page lists `SFU MATH 151 (3)` and `UBCV MATH_V 100 (3)` as its transfer equivalents. UBC Okanagan's `MATH_O 100` is the same idea under a longer title. Whether SFU and UBC cover parametric and polar curves (c1-63 to c1-67) was not checked.

## Licence statement

All 70 problems are original: the functions, numbers and wording were written for this bank. None is copied or adapted from a textbook, Studocu, Chegg or a past exam. No NonCommercial-licensed material (OpenStax Calculus, Active Calculus and similar) was used at all. The standard topics (a ladder sliding down a wall, an open box cut from a square sheet, a closed can of fixed volume) are generic textbook-genre setups with fresh numbers, not copies. No third-party licence applies to the bank.

## Verification

Run, with sympy importable:

```
uv run --with sympy python -I shared/courses/calculus-1/verify.py
```

Last run 2026-11-14 with sympy 1.14.0: format ok for 70 problems, `verified 70 of 70`, exit 0.

What `verify.py` does for each id:

1. Recomputes the answer from the prompt's own function and numbers (`sp.limit`, `sp.diff`, `sp.idiff`, `sp.solve`, antiderivatives checked by differentiating the claimed answer).
2. Recomputes the key intermediate results the worked solution relies on: the cancelled form of a limit, each derivative, critical numbers and the test values at them, the Newton iterates as exact fractions, and for word problems the derived equation (for example `V = πh³/12`, `3x + y = 240`, `s² = x² + 9`) and the numeric answer.
3. Asserts that the verified value appears in `final_answer` (single-digit answers must match exactly), so the text cannot drift from the math. A deliberate test confirmed it: seven final answers were changed on purpose and all seven were flagged.

Not mechanically checked: the wording of each prose step. The numbers stated in the steps were re-read by hand against the sympy results, but `verify.py` does not parse the sentences. Optimization problems also confirm the maximum or minimum by a second-derivative sign and, in c1-50 and c1-53 a brute-force search.
