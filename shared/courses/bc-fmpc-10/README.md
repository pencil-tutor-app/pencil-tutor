# BC Foundations of Mathematics and Pre-calculus 10 (Pencil Tutor problem bank)

- Course folder: `shared/courses/bc-fmpc-10/`
- Problem ids: `f10-01` to `f10-54` (54 problems), `level` = `high_school`
- Format: identical to `shared/problems.json` (`id`, `source`, `prompt_latex`, `prompt_plain`, `prompt_parts`, `worked_solution[]`, `final_answer`, `level`)
- Workplace Mathematics 10 is deliberately not covered (out of scope for this bank).

## Official curriculum (spine)

- Course page: https://curriculum.gov.bc.ca/curriculum/mathematics/10/foundations-of-mathematics-and-pre-calculus (fetched 2026-11-14)
- Elaborations PDF (not used for content, listed for teachers): https://curriculum.gov.bc.ca/sites/curriculum.gov.bc.ca/files/curriculum/mathematics/en_mathematics_10_foundations-of-mathematics-and-pre-calculus_elab.pdf

Full list of Content standards on that page (10 of them), in the page's order:

1. operations on powers with integral exponents (positive and negative exponents; exponent laws; evaluation using order of operations; numerical and variable bases)
2. prime factorization (expressing prime factorization of a number using powers; identifying the factors of a number; includes GCF and LCM; strategies include factor trees and factor pairs)
3. functions and relations: connecting data, graphs, and situations (domain and range in situational and non-situational contexts; connecting graphs and context; meaning of a function; identifying whether a relation is a function; function notation)
4. linear functions: slope and equations of lines (slope positive, negative, zero, undefined; point-slope, slope-intercept and general form; parallel and perpendicular lines; horizontal and vertical lines; connections between graphs, tables, equations)
5. arithmetic sequences (common difference, first term, general term; connecting to linear relations; extension: arithmetic series)
6. systems of linear equations (graphically; algebraically by inspection, substitution, elimination; ordered pair as solution; situational problems)
7. multiplication of polynomial expressions (distributive property, including trinomials; area model for binomial products)
8. polynomial factoring (GCF of a polynomial; trinomials x^2 + bx + c; difference of squares)
9. primary trigonometric ratios (sin, cos, tan; right-triangle problems with the Pythagorean theorem; direct and indirect measurement)
10. financial literacy: gross and net pay (types of income; income tax and other deductions)

## Standard to problem map

| # | Content standard | Problem ids | Notes |
|---|---|---|---|
| 1 | powers with integral exponents | f10-01 to f10-05 | positive/negative exponents 01, 03, 04, 05; laws 01, 03, 04; order of operations 02, 05; variable bases 03, 04 |
| 2 | prime factorization | f10-06 to f10-10 | powers form 06; GCF 07, 10; LCM 08; perfect square 09; factor pairs/trees used throughout |
| 3 | functions and relations | f10-11 to f10-16 | function test and domain/range 11, 12; function notation 13, 14, 16; situational domain/range 15 |
| 4 | linear functions | f10-17 to f10-23 | slope 17, 18; horizontal/vertical lines 18; point-slope to slope-intercept 19; general form 20; parallel 21; perpendicular 22; table to equation 23 |
| 5 | arithmetic sequences | f10-24 to f10-28 | d and t_n 24, 25; from two terms 26; context 27; series (extension) 28 |
| 6 | systems of linear equations | f10-29 to f10-34 | table/inspection 29; substitution 30; elimination 31, 32; no solution 33; situational 34 |
| 7 | multiplication of polynomials | f10-35 to f10-39 | binomials 35, 36; square of a binomial 37; binomial times trinomial 38; area model 39 |
| 8 | polynomial factoring | f10-40 to f10-44 | GCF 40; x^2 + bx + c 41, 42; difference of squares 43; GCF then trinomial 44 |
| 9 | primary trigonometric ratios | f10-45 to f10-49 | ratios 45; missing side 46, 49; missing angle 47, 48; Pythagorean theorem 48; indirect measurement 49 |
| 10 | financial literacy: gross and net pay | f10-50 to f10-54 | hourly 50; overtime 51; commission 52; deductions and net 53; salary per pay period 54 |

### Skipped or partial (honest gaps)

- Curricular Competencies (reasoning and modelling, understanding and solving, communicating and representing, connecting and reflecting, including First Peoples perspectives, puzzles and games, discussion and reflection) are process standards, not written-work content, so no problems are written for them. The problems still ask for estimating, checking, and modelling in context.
- "Connecting graphs and context" (standard 3) and "solving graphically" (standard 6): prompts here are text only, so graphs are represented by tables of values and described situations (f10-15, 16, 23, 29), not by reading a drawn graph.
- Standard 10 "types of income" and "income tax and other deductions" are given as short computational versions. Deduction amounts in f10-53 are given in the problem; no real CPP, EI or income-tax rates are used or claimed.
- Technology/manipulative standards (graphing technology, algebra tiles) are not testable on paper.

## Closest Ontario and Alberta courses

Ontario (curriculum: Ministry of Education; course list https://www.dcp.edu.gov.on.ca/en/course-descriptions-and-prerequisites/mathematics , updated August 2026; 2005 Grades 9 and 10 document https://www.edu.gov.on.ca/eng/curriculum/secondary/math910curr.pdf ; Grade 9 course MTH1W, 2021, https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics):

- Closest: Grade 10 Principles of Mathematics, Academic (MPM2D). Its course description (verified in the 2005 PDF) lists quadratic relations, solving and applying linear systems, analytic geometry of figures, and the trigonometry of right and acute triangles.
- Also related: Grade 10 Foundations of Mathematics, Applied (MFM2P), and Grade 9 Mathematics, De-streamed (MTH1W, 2021), which has Number (including exponents), Algebra (linear relations) and Financial Literacy strands (strand names verified in the 2021 PDF; keyword counts only, specific expectations not read line by line).
- Main differences from BC Foundations and Pre-calculus 10: Ontario MPM2D spends most of the year on quadratic relations (factoring, completing the square, vertex form), which BC covers in Grade 11 (unverified: from memory, not checked this session). BC Grade 10 has arithmetic sequences, prime factorization with GCF/LCM, function notation and gross/net pay in the course; the Ontario Grade 10 descriptions do not list sequences (sequences appear in Grade 11, MCR3U, unverified: from memory, not checked in this session), and financial literacy sits in Grade 9 (MTH1W strand F).
- Systems of linear equations: in Ontario Grade 10 (MPM2D description) and in BC Grade 10; the Grade 9 PDF has no hits for "systems of linear".

Alberta (Mathematics 10-12 program of studies; Mathematics 10C: https://curriculum.learnalberta.ca/curriculum/en/pos/mat_hs/mat1791 , page is script-rendered and returned no text; the outcomes were read from the official PDF "Outcomes with assessment standards for Mathematics 10C, 2012" https://open.alberta.ca/dataset/e639a847-7360-439a-a349-535fdc232862/resource/31fea684-5cc5-4e5b-a24f-3ad4e801904e/download/6026440-2012-06-outcomes-with-assessment-standards-for-mathematics-10c-2012.pdf ; program of studies listing https://open.alberta.ca/publications/9780778564393):

- Closest: Mathematics 10C (Alberta's pathways split at Grade 11 into 20-1, 20-2 and 20-3, much like BC's Foundations versus Pre-calculus split; the pathway names are unverified, from memory).
- 10C outcomes (verified from the PDF): Measurement (SI and imperial linear measure and conversions; surface area and volume of 3-D objects; primary trigonometric ratios); Algebra and Number (factors, GCF, LCM, square and cube roots; irrational numbers; powers with integral and rational exponents; multiplying polynomials; common factors and trinomial factoring); Relations and Functions (relations and functions, domain and range, slope, linear relations and their forms, equations of lines, parallel and perpendicular, function notation, systems of linear equations in two variables).
- Main differences from BC: Alberta 10C adds rational exponents, irrational numbers, unit conversion, and surface area/volume of 3-D objects. BC Grade 10 adds arithmetic sequences and gross/net pay; neither appears in the 10C outcomes list (checked against the outcome titles only). Alberta factoring includes ax^2 + bx + c, while BC Grade 10 stops at x^2 + bx + c and difference of squares.
- Alberta's 2012 PDF predates any revision; confirm the current Alberta program of studies before treating the Alberta mapping as final.

Unverified: exact current sequencing of Alberta and Ontario topics across grades beyond what is listed above, and any 2025-2026 curriculum revisions in either province.

## Originality statement

Every problem was written for this bank from the BC content standards. No problem, number set, wording, diagram, or answer was copied or adapted from a textbook (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math and others), Studocu, Chegg, or any provincial exam, and no NonCommercial-licensed material was used. Contexts (tickets, ramps, taxi fares, payslips) are generic. No student names appear anywhere; fictional people are not named.

## Verification method

Re-runnable: `python3 -I shared/courses/bc-fmpc-10/verify.py` (standard library only, exits non-zero on any failure).

Last run: 2026-11-15, result `54 problems, 54 verified, 0 failed; 247 intermediate pairs checked, 70 prose-only lines skipped`.

For every problem the script checks:

1. Schema matches `shared/problems.json` and `prompt_plain` equals the concatenation of `prompt_parts`.
2. The final answer, recomputed from the givens (read back out of `prompt_plain` where it is a clean expression): Fractions for exact arithmetic, a linear solver for equations and 2x2 systems, brute force for word problems and number theory, interpolation for polynomial coefficients and GCF checks, and the `math` module for trig and rounding.
3. Intermediate lines: a small Unicode-math evaluator parses each `A = B = C` chain in `worked_solution` and checks neighbouring pairs are equal (within 0.2% for the "≈" lines). Equations are checked at the answer values, algebraic identities at random rational values, and line equations at sample points of the correct line (and the final line equation is confirmed false off the line). Prose-only lines are skipped and counted; trig decimals are checked separately against `math`.
4. Mutation test: four deliberate errors injected into a copy (a wrong final answer, a wrong sum in a step, a wrong constant in a line, a wrong expansion) were all caught.

What this does not prove: wording quality, age-appropriateness, and the pedagogy of each step are not machine-checked, and prose lines are unchecked beyond the targeted assertions above.

## Review (teacher-quality pass, 2026-11-15)

Checked all 54 problems for: one clear answer, grade 10 wording, Canadian/metric context, fit to FMPC 10, worked
solution one step per line, final answer matching the ask, rounding, difficulty ramp, no names or recognisable textbook items.

- Reviewed 54, fixed 3, dropped 0, unchanged 51.
- f10-23: same table and answer (y = 3x + 5, 35) as m8-27 in Math 8; now y = 12, 9, 6, 3, giving y = −3x + 12 and −18. verify.py updated.
- f10-42: factored the exact polynomial expanded in f10-35 (x² − 3x − 28); now x² − 2x − 24 = (x + 4)(x − 6). verify.py updated.
- f10-54: `0.78 × 54000 ÷ 26 = 1620` was two steps in one line; now net for the year (42120), then per pay period.
- Most common finding: none dominant; the bank was clean (trig rounding, units and pay arithmetic all re-derived by hand).
- verify.py: passes (54 problems, 54 verified, 0 failed, 247 pairs).
- Unsure: f10-28 (arithmetic series) is labelled "Extension", matching the curriculum's "extension: arithmetic series".
