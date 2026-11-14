# BC Foundations of Mathematics 12: problem bank (`fm12`)

46 original problems for Pencil Tutor, level `high_school`, in the format of `shared/problems.json`.

## Official curriculum

- Content standards (retrieved 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/12/foundations-of-mathematics

Full list of Content standards, copied from the page:

1. geometric explorations: constructions (perpendicular bisector, tangents, polygons, tessellations, geometric art); conics (locus definition and constructions, conic sections, applications); fractals (understanding fractals as an iteration of a simple instruction; constructing and analyzing models such as Cantor's dust, Serpinski's triangle, Koch's snowflake; connecting fractals with nature)
2. graphical representations of polynomial, logarithmic, exponential, and sinusoidal functions: using technology only; using characteristics of a graph to identify these functions
3. regression analysis: polynomial, exponential, sinusoidal, logarithmic; applying the appropriate regression model
4. combinatorics: permutations, combinations, pathways, Pascal's Triangle
5. odds, probability, and expected value: mutually exclusive, non mutually exclusive, conditional probability, binomial probability; Venn diagrams
6. financial planning: developing a personal financial portfolio; mortgages; risk; changing interest rates and/or payments; credit cards; exploring banking options and financial markets

The six headings were split into 8 groups (geometric explorations into constructions, conics and fractals) so each group gets 4 to 9 problems.

## Standard to problem ids

| Content standard (as written in this bank) | Count | Problem ids |
|---|---|---|
| BC Foundations of Mathematics 12 content: geometric explorations, constructions (perpendicular bisector, tangents, polygons, tessellations) | 5 | fm12-01 to fm12-05 |
| BC Foundations of Mathematics 12 content: geometric explorations, conics (locus definition and constructions, conic sections, applications) | 6 | fm12-06 to fm12-11 |
| BC Foundations of Mathematics 12 content: geometric explorations, fractals (iteration of a simple instruction; Cantor dust, Sierpinski triangle, Koch snowflake) | 4 | fm12-12 to fm12-15 |
| BC Foundations of Mathematics 12 content: graphical representations of polynomial, logarithmic, exponential and sinusoidal functions (using characteristics of a graph to identify them; the curriculum says technology only, so these are short characteristic-reading versions) | 4 | fm12-16 to fm12-19 |
| BC Foundations of Mathematics 12 content: regression analysis (polynomial, exponential, sinusoidal, logarithmic; applying the appropriate model; by hand versions of the model step) | 4 | fm12-20 to fm12-23 |
| BC Foundations of Mathematics 12 content: combinatorics (permutations, combinations, pathways, Pascal's triangle) | 7 | fm12-24 to fm12-30 |
| BC Foundations of Mathematics 12 content: odds, probability and expected value (mutually exclusive, non mutually exclusive, conditional, binomial; Venn diagrams) | 9 | fm12-31 to fm12-39 |
| BC Foundations of Mathematics 12 content: financial planning (mortgages, risk, changing interest rates and payments, credit cards, banking options) | 7 | fm12-40 to fm12-46 |

## Skipped or reduced standards

- "geometric art" and "connecting fractals with nature": discussion or art tasks, not written work. Skipped.
- Compass and straightedge constructions: physical drawing. Replaced with coordinate versions (perpendicular bisector equation, tangent equation, circumcentre) that give the same result by hand.
- "using technology only" (graphical representations, regression): the curriculum wording means a graphing calculator or software does the fitting. These are reduced to short hand-readable versions: identify a function from its stated characteristics, fit a two point exponential model, convert a linearized fit, build a sinusoidal model from max/min, and compare sums of squared residuals. A real regression run (many data points, correlation) is not a pen and paper task and is not included.
- "developing a personal financial portfolio" and "exploring banking options and financial markets": research and projects. Reduced to the computational core: compound growth (`fm12-40`), effective annual rate comparison (`fm12-45`), expected return and risk (`fm12-46`).
- Mortgage problems assume interest compounded monthly so the payment formula is simple. Canadian fixed rate mortgages usually compound semi-annually (general knowledge, not sourced here); a note for the tutor, not a flaw in the arithmetic.
- Curricular Competencies are not content and have no written-work problems.

## Ontario and Alberta equivalents (closest courses)

BC Foundations of Mathematics 12 has no single match; it blends pieces of several courses.

| BC strand | Ontario | Alberta |
|---|---|---|
| Combinatorics, probability, expected value, binomial | Mathematics of Data Management, Grade 12, University (MDM4U): counting and probability, probability distributions, data analysis. Course list: https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses-list ; prerequisites: https://www.dcp.edu.gov.on.ca/en/course-descriptions-and-prerequisites/mathematics | Mathematics 30-2 (counting, probability, logical reasoning; also rational expressions, logarithms, polynomial and sinusoidal functions). Program of studies: https://curriculum.learnalberta.ca/curriculum/en/pos/MAT_HS/MAT1791 ; family page: https://curriculum.learnalberta.ca/parents/en/grade/hs/mat/mat3792 |
| Financial planning, regression | Foundations for College Mathematics, Grade 12, College (MAP4C) is the closest college stream course; same course list link as above. The detailed MAP4C topic list was not read (unverified). | Mathematics 30-2 touches exponential, logarithmic, polynomial and sinusoidal functions; financial planning in the BC sense is nearer Alberta Mathematics 30-3 (financial situations, linear relations, probability): https://curriculum.learnalberta.ca/parents/en/grade/hs/mat/mat3793 |
| Conics, constructions, fractals | No named equivalent found in the Grade 12 Ontario course titles (unverified) | No named equivalent found in the Alberta 30-level descriptions read (unverified) |

Main differences (**unverified line by line**, from course descriptions only): BC Foundations is the one Grade 12 course here that makes geometry (conics, constructions, tessellations, fractals) and personal finance part of the same course as probability and regression. Ontario and Alberta spread those across separate courses or omit them at Grade 12.

## Originality statement

Every prompt, worked solution and number in this bank was written from scratch for this project. Nothing was copied or adapted from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math and similar), from Studocu or Chegg, or from provincial exams. Numbers were chosen for clean by-hand work. No student names appear anywhere.

## Verification (2026-11-14)

`verify.py` is both the spec and the checker, standard library only. Run from this folder:

```
python3 -I verify.py            # re-check problems.json against the spec and re-run every maths check
python3 -I verify.py --write    # regenerate problems.json from the spec
```

Each problem has a check that recomputes the result independently: brute force enumeration for counting and probability (all permutations, all 6-flip coin sequences, lattice path recursion, a 52 card deck), exact `Fraction` arithmetic, distance checks that sample points on each locus or conic (equidistant from focus and directrix, constant sum of focal distances, points on a circle), sums of squared residuals, and loan amortisation for the mortgage and payment-count problems. Money answers are rounded half up to cents. Closed forms are proved equal to numeric values and the printed string is compared with `final_answer`. The script exits 1 if any check fails, if ids repeat, or if `problems.json` differs from the spec.

Result on 2026-11-14: 46 of 46 problems verified, 0 failures (one check was wrong on the first run, a mistaken T(26) value in the temperature model, and was corrected; the answer itself was right).

Not verified mechanically: the wording of worked steps (read by hand), the Ontario/Alberta comparison above.

## Review (2026-11-15)

Teacher-quality read of all 46 problems against seven checks: one unambiguous answer, age-appropriate wording and Canadian context, fit to BC Foundations of Mathematics 12, worked solution reads like a student's lines, final answer matches the request, difficulty ramp inside each group, no names or recognisable textbook problems.

- Reviewed 46, fixed 7, dropped 0, unchanged 39. `python3 -I verify.py` passes 46 of 46.
- Fixed: `fm12-03` (asks for each interior and each exterior angle), `fm12-11` (asks for the coordinates of the focus), `fm12-22` (the sinusoidal model was not unique; now a > 0, b > 0 and c is the time of the maximum), `fm12-30` (Pascal row numbering varies by book; the prompt now says the row that begins 1, 4), `fm12-39` (says the player is paid $6, so the net is unambiguous), `fm12-40` (the worked line used 1.19689 and gave 5984.45, not the stated 5984.47; now carries 1.1968948), `fm12-42` (answer shown as "$226 131" in the same style as the prompt; it is exact for the stated payment, so "about" was dropped; `verify.py` check changed to match).
- Most common problem: a prompt with more than one defensible answer, then a rounding line that did not reproduce the printed answer.
- Unsure: hyperbola foci and asymptotes (`fm12-09`) and ellipse foci (`fm12-08`) may be deeper than the Foundations 12 conics outcome ("locus definition and constructions, conic sections, applications"; the elaborations ask how circles, ellipses, parabolas and hyperbolas are related) and were kept. Mortgage problems compound monthly as the prompt states; Canadian fixed-rate mortgages usually compound semi-annually (already noted above).
