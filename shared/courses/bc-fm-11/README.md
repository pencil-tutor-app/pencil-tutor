# BC Foundations of Mathematics 11: original problem bank for Pencil Tutor

60 original problems in the `shared/problems.json` format (level `high_school`, ids `fm11-01` to `fm11-60`). Each is worked by hand on a page in 3 to 7 written lines (most 4) with clean numbers. Files in this folder: `problems.json`, `verify.py`, this README.

## Official curriculum
- Source (fetched 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/11/foundations-of-mathematics
- Content standards, as published (Content section of the page above):

```
forms of mathematical reasoning
- logic, conjecturing, inductive and deductive thinking, proofs, game/puzzle analysis, counter-examples

angle relationships
- properties, proofs, parallel lines, triangles and other polygons, angle constructions

graphical analysis (using technology only)
- linear inequalities: graphing of the solution region; slope and intercepts; intersection points of lines
- quadratic functions: characteristics of graphs, including end behaviour, maximum/minimum, vertex, symmetry, intercepts
- systems of equations: including linear with linear, linear with quadratic, and quadratic with quadratic
- optimization: using feasible region to optimize objective function; maximizing profit while minimizing cost; maximizing area or volume while minimizing perimeter

applications of statistics
- posing a question about an observed variation, collecting and interpreting data, and answering the question
- measures of central tendency, standard deviation, confidence intervals, z-scores, distributions

scale models
- enlargements and reductions of 2D shapes and 3D objects
- comparing the properties of similar objects (length, area, volume)
- square-cube law

financial literacy: compound interest, investments and loans
- compound interest
- introduction to investments/loans with regular payments using technology
- buy/lease
```

## Standard to problem ids

| Content standard (topic group) | Problems | Ids |
|---|---|---|
| forms of mathematical reasoning (inductive and deductive reasoning, proof, counter-examples, logic, game analysis) | 7 | fm11-01 to fm11-07 |
| angle relationships (parallel lines, triangles, polygons, proofs, constructions) | 10 | fm11-08 to fm11-17 |
| graphical analysis: linear inequalities (solution region, slope and intercepts, intersection points) | 4 | fm11-18 to fm11-21 |
| graphical analysis: quadratic functions (end behaviour, vertex, maximum/minimum, symmetry, intercepts) | 4 | fm11-22 to fm11-25 |
| graphical analysis: systems of equations (linear-linear, linear-quadratic, quadratic-quadratic) | 6 | fm11-26 to fm11-31 |
| graphical analysis: optimization (feasible region, objective function, profit and cost, area and volume) | 6 | fm11-32 to fm11-37 |
| applications of statistics (central tendency, standard deviation, z-scores, distributions, confidence intervals) | 8 | fm11-38 to fm11-45 |
| scale models (enlargements and reductions, similar objects, square-cube law) | 9 | fm11-46 to fm11-54 |
| financial literacy: compound interest, investments and loans, buy/lease | 6 | fm11-55 to fm11-60 |

## Standards not set as written work, or set differently
- Curricular Competencies: ways of working, not computable content, so no problems of their own.
- "Graphical analysis ... using technology only": the BC standard assumes graphing technology. These problems are the same mathematics done by hand (substitution and elimination for systems, corner-point evaluation for optimization, completing the square or the axis formula for parabolas). That is a deliberate deviation so the Apple Pencil tutor has hand work to watch. Grid-and-shade drawing tasks are described in words because the prompt format has no figures.
- "Posing a question about an observed variation, collecting and interpreting data, and answering the question": a data-collection project, not written work. Replaced by computation on a given data set (mean, median, mode, standard deviation, z-scores, empirical rule, 95% confidence intervals). "Distributions" is covered only through the normal distribution.
- "Angle constructions": one problem describes a compass-and-straightedge construction in words (75° from 60° and two bisections); physical drawing is not checked.
- "Game/puzzle analysis": one game (a subtraction game with winning strategy) and one number-trick proof; no more.
- Linear programming with more than two variables, and the "technology only" parts of financial literacy (spreadsheet amortization tables): not covered. Loans and annuities use the closed formulas with a calculator.

## Closest Ontario and Alberta courses

Ontario:
- Closest course: **Foundations for College Mathematics, Grade 11, College Preparation (MBF3C)**. Official ministry document (2007, the version our fetch returned): https://www.edu.gov.on.ca/eng/curriculum/secondary/math1112currb.pdf . Course page: https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses/mbf3c returned "Page not found" on 2026-11-14, so only the PDF was read. Strand headings found in the PDF: Mathematical Models, Personal Finance, Geometry and Trigonometry, Data Management. Second closest: **Functions and Applications, Grade 11, University/College (MCF3M)** (same PDF).
- Overlap: compound interest and personal finance (13 keyword hits in the MBF3C section), quadratic models, descriptive statistics (standard deviation appears twice), and a single mention of scale.
- Main differences (keyword counts in the MBF3C section, indicative only, unverified beyond that): no optimization or linear programming (0 hits), and no z-scores (0 hits for "z-score"; confidence intervals were not searched). Ontario MBF3C also puts sine law and cosine law in Grade 11 college (9 hits), while BC puts them in Pre-calculus 11, not in Foundations 11, so this bank has no trigonometry.
- Status caveat: Ontario has been revising secondary mathematics; the 2007 text may not be current. Unverified.

Alberta:
- Closest course: **Mathematics 20-2** (Program of Studies, 2008). Official page (read in full): https://curriculum.learnalberta.ca/curriculum/en/pos/MAT_HS/MAT2792 . Outcomes with assessment standards (listed in search results, not opened): https://open.alberta.ca/publications/9781460111833
- Overlap (verified from the outcome list): scale factors, areas, surface areas and volumes of similar 2-D and 3-D objects; angle and triangle properties and proofs; inductive and deductive reasoning and conjectures; analysis of puzzles and games; normal distribution, standard deviation and z-scores; confidence intervals, confidence levels and margin of error; characteristics of quadratic functions and quadratic equations.
- Alberta 20-2 adds (not in BC Foundations 11): rates, operations on radicals and radical equations, sine law and cosine law (without the ambiguous case), a mathematics research project.
- BC Foundations 11 adds (not in the Alberta 20-2 outcome list as fetched): linear inequalities and their solution regions, systems of equations (linear-quadratic, quadratic-quadratic), optimization with a feasible region, financial literacy (compound interest, loans, buy/lease).
- Status caveat: whether the 2008 program of studies is still the current Alberta Grade 11 text was not checked. Unverified.

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
- `prompt_parts` uses only `text` and `frac` parts, as in `shared/problems.json`. Word problems keep the prose in `prompt_plain` and `prompt_latex` (the LaTeX field is a mechanical conversion of the plain text, with prose left as prose).
- Angles are in degrees. Money answers are rounded to the cent; intermediate decimals in worked solutions are shown to five places so the student can follow the rounding.
- Graphical-analysis problems are the hand versions described under "Standards not set as written work or set differently".


## Review (teacher-quality pass, 2026-11-15)
Every one of the 60 problems was read as a teacher would: one intended answer (units, rounding, form stated), age-appropriate wording, fit with BC Foundations of Mathematics 11, one step per worked line, final answer matching the request, difficulty ramp inside each standard, no duplicated problems, no names, no recognisable textbook or exam items. `verify.py` was updated for every change and `python3 -I verify.py` passes (60/60).

- Counts: 60 reviewed, 6 fixed, 0 dropped, 54 unchanged. Ids are unchanged.
- Fixed: fm11-22 and fm11-23 ("Analyse" to Canadian "Analyze"), fm11-34 (the cheapest mix was a single feed, not a mix; prices swapped so the best corner is a genuine mix, 6 kg A and 4 kg B at $24; the prompt now defines x and y), fm11-39 (was the very well known 2, 4, 4, 4, 5, 5, 7, 9 example; now six page counts, same answer 2), fm11-44 (said "standard deviation" without population or sample; now says population and the rounding), fm11-60 (asked for logarithms, which are not in Foundations 11; now a calculator trial-and-error check, 12 years).
- Most common problem: content from a later course or an unstated convention (logarithms in fm11-60, population versus sample in fm11-44).
- Unsure: fm11-01 uses n^2 + n + 11, a close cousin of the famous n^2 + n + 41; the numbers are different and the counterexample (n = 10) is original, so kept. The "technology only" graphing standard is still done by hand, as the README already says.
