# BC Mathematics 9: problem bank (`m9-01` to `m9-49`)

49 hand-solvable problems in the app's `problems.json` format (`level: "high_school"`). Each is worked in 3 to 6 written
lines. Ordered easy to hard inside each standard. Verified by `verify.py` on 2026-11-14.

## Official curriculum

- Course page: <https://curriculum.gov.bc.ca/curriculum/mathematics/9>
- Content and competencies: <https://curriculum.gov.bc.ca/curriculum/mathematics/9/core>
- Fetched 2026-11-14. Content learning standards (the full list, in the ministry's order and wording):
  1. operations with rational numbers (addition, subtraction, multiplication, division, and order of operations); includes brackets and exponents
  2. exponents and exponent laws with whole-number exponents; includes variable bases; limited to whole-number exponents and whole-number exponent outcomes when simplified
  3. operations with polynomials, of degree less than or equal to 2
  4. two-variable linear relations, using graphing, interpolation, and extrapolation; includes rational coordinates, horizontal and vertical lines
  5. multi-step one-variable linear equations; includes distribution, variables on both sides, collecting like terms, rational coefficients, constants and solutions
  6. spatial proportional reasoning: scale diagrams, similar triangles and polygons, linear unit conversions (metric units only)
  7. statistics in society: population versus sample, bias, ethics, sampling techniques, misleading stats
  8. financial literacy: simple budgets and transactions (banking, simple interest, savings, planned purchases)

## Standard to problem ids

| # | Standard | Problem ids | Count |
|---|---|---|---|
| 1 | Operations with rational numbers | m9-01 to m9-06 | 6 |
| 2 | Exponents and exponent laws (whole-number) | m9-07 to m9-12 | 6 |
| 3 | Polynomials, degree 2 or less | m9-13 to m9-18 | 6 |
| 4 | Two-variable linear relations | m9-19 to m9-24 | 6 |
| 5 | Multi-step linear equations | m9-25 to m9-30 | 6 |
| 6 | Spatial proportional reasoning | m9-31 to m9-37 | 7 |
| 7 | Statistics in society | m9-38 to m9-43 | 6 |
| 8 | Financial literacy (simple interest, budgets, transactions) | m9-44 to m9-49 | 6 |

Sources: 35 of the 49 are Edward's own tutoring problems, converted to the app format and re-verified (the `source`
field names the unit and item number in the tutoring repo's `curriculum/bc-math-9/units/*/practice/extra-practice.md`).
14 are new, written for this bank to fill gaps (ids m9-02, 06, 08, 15, 16, 20, 24, 29, 32, 33, 38, 40, 44, 49).
Error-hunt items keep the "find the first wrong line" format but say "a student" with no name.

## Skipped or shortened (not written work)

- Curricular-competency items (coding, games, modelling through play, First Peoples place-based inquiry, "model with
  manipulatives or algebra tiles"): not content standards and not hand-written work; no problems.
- Standard 6 contexts such as First Peoples mural scale work and longhouse models: replaced by plain metric scale-drawing
  and similar-triangle computations.
- Standard 7: ethics, privacy, cultural sensitivity and the Statistics Canada / First Peoples water-quality data
  discussions are discussion tasks. Only the computational slices are here: identifying population and sample, naming the
  bias factor, stratified-sample arithmetic (m9-40), predicting from a sample (m9-41), a truncated-axis graph (m9-42), and
  percentages that cannot all be right (m9-43). Answers to m9-38 and m9-39 are short written phrases, not numbers.
- Standard 8: "creating a budget/plan to host an event" is a project. Replaced by short computational versions
  (m9-44 account transactions, m9-49 saving toward a purchase).
- Graphing in standard 4: the prompt cannot draw a grid, so graph problems ask for the equation, table-derived values and
  interpolation or extrapolation answers; m9-21 asks the student to sketch from two points but grades the equation.
- Negative exponents appear in the tutoring repo's unit 6 practice. They are outside BC Math 9 (whole-number exponents
  only), so none were converted.

## Closest Ontario and Alberta courses

| | Course | Official source |
|---|---|---|
| Ontario | Grade 9 Mathematics, de-streamed, MTH1W (2021) | <https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses/mth1w> (PDF: "The Ontario Curriculum, Mathematics Grade 9 De-streamed Course 2021") |
| Alberta | Mathematics Grade 9, Alberta Program of Studies, Mathematics K-9 (2007, updated 2014) | <https://open.alberta.ca/publications/5360906> |

Both sources were fetched on 2026-11-14 and the differences below come from their text. Ontario's list is from the
expectation statements (strands B to F) and their teacher-support examples. Items marked (unverified) are my reading
and were not cross-checked against a second source.

**Alberta** is almost the same course, because Alberta's program derives from the Western and
Northern Canadian Protocol framework (per its catalogue entry), which BC also used for its earlier Math 9 (unverified):
- Same: powers with integer bases and whole-number exponents with the exponent laws; rational-number operations and order
  of operations; graphing a linear relation with interpolation and extrapolation; linear equations with rational
  coefficients (ax + b = cx + d, a(bx + c) = d(ex + f)); polynomials of degree 2 or less; scale diagrams and similar
  polygons; effects of bias, language, ethics, cost, timing, privacy, cultural sensitivity; population versus sample.
- Alberta adds: square roots of rational numbers, single-variable linear inequalities, circle properties, surface area of
  composite 3-D objects, line and rotation symmetry, probability. BC Math 9's content list (above) has none of these.
- Alberta has no simple-interest or budget outcome at Grade 9 in the Program of Studies text I read (unverified: a
  financial-literacy strand may sit in another subject).
- Alberta's Grade 7 to 9 mathematics is being renewed: a draft 7 to 9 curriculum was released for field testing in
  2025 and 2026 (<https://alberta.ca/curriculum-mathematics>). The 2007 program above is the one I mapped.

**Ontario** MTH1W differs more:
- Exponents: Ontario works with rational bases and integer exponents (including negative and zero exponents, scientific
  notation); BC limits to whole-number exponents.
- Algebra: Ontario simplifies monomials of degree 1 to 3 and multiplies a monomial by a monomial or binomial; BC limits
  to degree 2 or less and includes dividing by a monomial.
- Linear relations: Ontario compares linear and non-linear relations and finds equations from graphs, tables and
  concrete representations (slope as rate of change, y-intercept as initial value). BC stresses graphing,
  interpolation and extrapolation.
- Data: Ontario has quartiles, box plots, scatter plots and regression with technology, plus the implications of large
  data collection. BC Math 9 has population/sample, bias and ethics instead.
- Geometry and measurement: Ontario has the side-length relationship for right triangles (Pythagorean theorem),
  prism, pyramid, cylinder and cone volumes, and effects of changing dimensions. I did not find a similar-triangles or
  scale-diagram expectation in the MTH1W strand list (unverified).
- Financial literacy: Ontario compares interest rates, borrowing times, interest types and down payments on the total
  cost of purchases. BC uses simple interest and simple budgets.

## Originality

Every problem is an original, written either by Edward for his tutoring practice sets (35 items; the practice files
for units 2, 6 and 8 state their problems are new and not copied from the class teacher's worksheets; I did not find
that statement in the parts of units 3, 4, 5 and 7 that I read, so for those items it is unverified) or written fresh for
this bank (14 items). Nothing was copied from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math),
Studocu, Chegg or provincial exams, and no non-commercial-licensed material was used. The tutoring repo's `students/`
folder was never opened. No student's name appears anywhere in this folder (checked by `verify.py`).

## Verification (2026-11-14)

Run it any time: `python3 -I shared/courses/bc-math-9/verify.py` (exit 0 = pass, 1 = any failure). It uses only the
standard library, with exact `Fraction` arithmetic. If `sympy` is importable it also solves the five equations and
checks six expression identities a second way.

- Result when written: all 49 problems pass. 49 final answers recomputed from the givens in the prompt, 57 pure-number
  equality chains inside the worked solutions evaluated (each line like `2.25 + 1.92 = 4.17` is checked true), 49
  structure checks, and the key intermediate results required to appear in each worked solution. The run with sympy
  (1.14.0) also passed.
- Equations are solved as the exact root of left minus right, then both sides are re-evaluated at that root.
  Polynomial and exponent expressions are checked as identities at 13 to 15 points. The error-hunt answer m9-17 is also
  checked to differ from the student's wrong answer at every test point.
- I tested the verifier by changing four answers and one worked-solution line in a scratch copy; it reported all five.
- Not checked by machine: the wording of the prose lines, the interpolation versus extrapolation labels (m9-22, m9-24),
  and the classification answers in m9-38 and m9-39. I read those by hand.

## Review (teacher-quality pass, 2026-11-15)

Checked all 49 problems for: one clear answer, grade 9 wording, Canadian/metric context, fit to the BC Math 9 standard,
worked solution one step per line, final answer matching the ask, difficulty ramp, no names or recognisable textbook items.

- Reviewed 49, fixed 14, dropped 0, unchanged 35.
- m9-01 to m9-07, m9-14 and m9-25 to m9-29 were bare expressions or equations with no instruction; added
  "Evaluate:", "Simplify:" or "Solve:" (prompt_plain, prompt_latex and prompt_parts).
- m9-19: the table was jammed into one line of text; reworded as "x = 3, 6, 9, 12 and y = 8, 7, 6, 5".
- m9-27: `7n + 4 = 6n` jumped straight to `n = −4`; two lines added. m9-29: two operations in one line, now split.
- Most common finding: missing instruction verb on a bare expression (13 of 14).
- verify.py: passes (49 problems, 57 chains, 0 failures). Plain python has no sympy, so the second-method check is skipped, as before.
- Unsure: thousands separators are written with commas (m9-12, m9-41); Canadian usage allows commas or spaces, so left.
  m9-21 keeps a one-line note about the graph being joined; it is brief, so left.
