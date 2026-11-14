# BC Mathematics 7 problem bank (m7)

64 original problems, level `middle_school`, format identical to `shared/problems.json`.

## Official source
BC Mathematics 7 (content standards, Big Ideas, Curricular Competencies):
https://curriculum.gov.bc.ca/curriculum/mathematics/7 (fetched 2026-11-14)

## Standard -> problem ids
| Content standard (verbatim) | Ids |
|---|---|
| multiplication and division facts to 100 (extending computational fluency) | m7-01 to m7-04 |
| operations with integers (addition, subtraction, multiplication, division, order of operations; no exponents) | m7-05 to m7-09 |
| operations with decimals (incl. brackets, no exponents) | m7-10 to m7-14 |
| relationships between decimals, fractions, ratios, and percents | m7-15 to m7-19 |
| discrete linear relations, using expressions, tables, and graphs | m7-20 to m7-24 |
| two-step equations with whole-number coefficients, constants, and solutions | m7-25 to m7-29 |
| circumference and area of circles | m7-30 to m7-34 |
| volume of rectangular prisms and cylinders | m7-35 to m7-39 |
| Cartesian coordinates and graphing | m7-40 to m7-44 |
| combinations of transformations | m7-45 to m7-49 |
| circle graphs | m7-50 to m7-54 |
| experimental probability with two independent events | m7-55 to m7-59 |
| financial literacy: financial percentage (sales tax, tips, discount, sale price) | m7-60 to m7-64 |

Skipped: the Curricular Competencies (reasoning, communicating, reflecting, connecting) and the Indigenous-context
activity suggestions in the elaborations (drum making, bentwood boxes, etc.) are not written computation, so no
problems target them. Fractions are not a listed Grade 7 content standard on the BC page, so none are drilled
beyond conversions (m7-15 to m7-19). Circle problems use pi = 3.14. Drawing/graphing tasks (plotting, constructing circle
graphs) are posed as computation (coordinates, angles, percents) since the app is text-prompted.

## Closest Ontario and Alberta courses
- Ontario: Mathematics Grade 7 (2020 curriculum), https://www.dcp.edu.gov.on.ca/en/curriculum/elementary-mathematics/grades/g7-math
  (page is JavaScript-rendered; fetch returned no expectations, so the topic list below is partly from secondary sources
  such as IXL and a TpT product listing and is UNVERIFIED against the official text). Likely differences: Ontario
  includes exponents in order of operations and sales tax at 13% HST (BC uses 5% GST + 7% PST); BC has circles,
  cylinder volume and transformations in Grade 7 where Ontario's 2020 Grade 7 emphasises algebra, data and
  spatial sense with different placement. Treat as unverified.
- Alberta: Mathematics Grade 7 (program of studies), https://curriculum.learnalberta.ca/parents/en/grade/7/mat
  (verified: the overview lists integers, decimals and percent problems, fraction-decimal relationships, two-step equations,
  circle radius/diameter/circumference, area of circles, four-quadrant plotting, reflections/rotations/translations,
  probability as ratios/fractions/percents, circle graphs). Differences from BC: Alberta adds fraction operations,
  area of triangles/parallelograms, geometric constructions and mean/median/mode; BC adds cylinder volume and tessellation.
  Detailed outcome-level mapping not verified.

## Originality
All problems were written fresh for this bank from the BC standards. Nothing was copied or adapted from textbooks,
Studocu, Chegg, provincial exams, or NonCommercial material. No student names appear.

## Verification
`verify.py` recomputes every answer independently (Fraction, Decimal, brute-force equation solving, geometry and
transformation rules) and checks the answer and key intermediate values appear in each problem's text, plus structure
(ids m7-01 to m7-64, `middle_school`). Run `python3 -I shared/courses/bc-math-7/verify.py`.
Result on 2026-11-14: 64 problems, 208 checks, 0 failures.
Limit: the check proves the numbers, not the prose of the worked steps.
