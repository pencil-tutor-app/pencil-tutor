# BC Mathematics 6 problem bank

Course: BC Mathematics 6 (Grade 6, age 11-12). Level in `problems.json`: `elementary`. Id prefix: `m6-`.
91 original problems, each worked by hand in 2 to 6 written lines with clean numbers.

## Official curriculum

- Official page (fetched 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/6/core
- The page has Big Ideas, Content, and Curricular Competency. This bank covers the 19 Content standards below.
  The Curricular Competency standards (reasoning, communicating, connecting, reflecting) are process skills, not
  topics, so they have no problems of their own; they show up in how the worked lines are written.

## Content standard to problem ids

| BC Grade 6 content standard | Problem ids |
| --- | --- |
| small to large numbers (thousandths to billions) | m6-01 to m6-04 (4) |
| multiplication and division facts to 100 (developing computational fluency) | m6-05 to m6-08 (4) |
| order of operations with whole numbers | m6-09 to m6-13 (5) |
| factors and multiples: greatest common factor and least common multiple | m6-14 to m6-18 (5) |
| improper fractions and mixed numbers | m6-19 to m6-22 (4) |
| introduction to ratios | m6-23 to m6-27 (5) |
| whole-number percents and percentage discounts | m6-28 to m6-32 (5) |
| multiplication and division of decimals | m6-33 to m6-37 (5) |
| increasing and decreasing patterns, using expressions, tables, and graphs as functional relationships | m6-38 to m6-42 (5) |
| one-step equations with whole-number coefficients and solutions | m6-43 to m6-47 (5) |
| perimeter of complex shapes | m6-48 to m6-52 (5) |
| area of triangles, parallelograms, and trapezoids | m6-53 to m6-57 (5) |
| angle measurement and classification | m6-58 to m6-62 (5) |
| volume and capacity | m6-63 to m6-67 (5) |
| triangles | m6-68 to m6-71 (4) |
| combinations of transformations | m6-72 to m6-77 (6) |
| line graphs | m6-78 to m6-81 (4) |
| single-outcome probability, both theoretical and experimental | m6-82 to m6-86 (5) |
| financial literacy: simple budgeting and consumer math | m6-87 to m6-91 (5) |

### Standards and parts skipped or reduced

- "numbers used in science, medicine, technology, and media" (sub-bullet of place value): no separate problem; the
  place value problems cover the number skills.
- "using graphic organizers (e.g., Venn diagrams)" for factors: replaced by listing factors and multiples.
- Hands-on parts (birchbark biting, pattern blocks, Cuisenaire rods, base-10 blocks, Lahal stick games, berry baskets,
  local-environment angle hunts, First Peoples art printmaking, Small Number stories, graphing language-loss data):
  not paper-and-pencil written work, so not included. The maths underneath is covered (grids for percent, tile
  patterns, coordinate transformations, spinner and coin probability, volume with cubes).
- "plotting points / drawing the image" for transformations: given as coordinates to compute by hand (no drawing).
- Line graphs: the student reads a described table and states the line's changes; drawing the graph is not checked.
- Financial literacy: short computational versions only (weeks to save, unit price, budget split, percent saved).
  The "informed decision making" discussion part is not written work.
- Coding / games / puzzles / technology competencies: skipped.

## Ontario and Alberta equivalents

Closest grade: Grade 6 in both provinces.

- Ontario, Grade 6 Mathematics (2020 curriculum): https://www.dcp.edu.gov.on.ca/en/curriculum/elementary-mathematics/grades/g6-math/strands
  - Verified from the page: strands are A Social-Emotional Learning, B Number (B1 Number Sense, B2 Operations),
    C Algebra (C1 Patterns and Relationships, C2 Equations and Inequalities, C3 Coding, C4 Mathematical Modelling),
    D Data (D1 Data Literacy, D2 Probability), E Spatial Sense (E1 Geometric and Spatial Reasoning, E2 Measurement),
    F Financial Literacy (F1 Money and Finances).
  - Main differences vs BC 6 (UNVERIFIED, from general knowledge of the Ontario 2020 document; the fetched page did
    not show the specific expectations): Ontario has financial literacy and a coding strand as formal strands and
    puts more weight on fraction/decimal/percent operations and rates; BC 6 has no coding strand and keeps
    fractions to improper/mixed numbers, ratio introduction and decimal multiplication/division.
- Alberta, Grade 6 Mathematics (new K-6 program of studies, 2022): https://curriculum.learnalberta.ca/curriculum/en/gfc/MAT
  and summary https://open.alberta.ca/dataset/da982352-b50d-49a2-8805-c9073a7ecebd/resource/ce28459e-b9ba-40bc-a96f-c03b71df31e0/download/edc-new-curr-k6-mathematics.pdf
  - Verified from the summary PDF (Grade 6): add, subtract, multiply and divide with standard procedures (algorithms);
    multiply fractions by natural numbers; calculate area and volume; solve algebraic equations; collect, graph and
    interpret data.
  - Main differences vs BC 6 (partly UNVERIFIED): Alberta states standard algorithms and fraction-times-whole-number
    explicitly, while BC 6 stresses mental math strategies and has no fraction multiplication; BC 6 has ratios,
    percent discounts and probability, which the Alberta summary line does not mention (check the full program of
    studies before relying on this).

## Originality

Every problem was written from scratch for this bank from the BC content standards. No problem was copied or adapted
from a textbook, workbook, provincial exam, Studocu, Chegg or any NonCommercial-licensed source. Story characters use
generic first names only; no student's name appears anywhere.

## Verification

Verified 2026-11-14 with `verify.py` (`python3 -I verify.py`, exit code 0 means all pass; non-zero means a failure).

1. Final answers: for each of the 91 problems, the answer is recomputed in Python straight from the problem
   statement (exact `Fraction` arithmetic, `math.gcd`/`math.lcm`, list/brute-force counting, coordinate formulas for
   translations/reflections/rotations, polygon and unit-square perimeter counting) and compared to `final_answer`.
2. Worked lines: every plain arithmetic equality written in a worked line (for example `12 × 3 = 36`) is re-evaluated
   exactly. Lines with letters, ratios or coordinate pairs are not checked this way (their final answers are still
   checked by step 1).
3. Format: ids, key order, level, `prompt_parts` rebuild `prompt_plain`, no student names.

Limits: the verifier checks numbers, not wording; the classification answers (angle and triangle names) are checked
as required words. Whether each problem is well-pitched for age 11-12 is a human judgment, not checked.

Re-run after the teacher review, 2026-11-15: 91/91 final answers match, 144 worked-line equalities correct, ALL OK.

## Review (teacher-quality pass, 2026-11-15)

Checked all 91 problems for: one clear answer, grade-6 wording, Canadian units and spelling, fit with the standard (re-read against the official Content list, fetched 2026-11-15), one-step-per-line worked solutions, answer form, difficulty ramp, duplicates, names.

- Reviewed 91, fixed 9, dropped 0, unchanged 82.
- Fixed: m6-69 (the stated sides 5, 5, 8 cm cannot go with angles 38, 71, 71: the 8 cm side would face a 106 degree angle; now 5, 5, 6 cm with 74, 53, 53); m6-82 (same 8-section 3 red / 2 blue / 3 green spinner as Grade 5 m5-81; now 4 red, 3 blue, 3 green out of 10, answer simplified to 2/5, TRUTH in `verify.py` updated); m6-77 (reflection step used the formula "12 - old x", now the same-distance-other-side move a student draws; prompt now says "corners"); m6-04 (addition shown in one line, now column by column); m6-01 and m6-03 (large numbers lacked space grouping); m6-05, m6-06, m6-08 ("in your head" removed, the student writes the steps on the iPad).
- Most common problem: unformatted or compressed worked lines (missing digit grouping, a whole column addition in one line).
- Checked and kept on purpose: m6-12 has a quotient of 7.5, which the official Content line allows ("quotients can be rational numbers"); m6-14 uses exponents in a prime factor phrase and m6-18 uses divisibility rules, both listed in the official factors-and-multiples elaboration; m6-05, m6-33, m6-34 and m6-87 echo examples printed in the BC curriculum text itself (23 x 4, 0.125 x 3, 7.2 / 9, allowance for a bicycle), which is the official source, not a textbook.
- Unsure: the standard "combinations of transformations" is covered by one true combination (m6-77) plus single transformations m6-72 to m6-76; adding a second combination would need a new id, so it was left. m6-37 (decimal times whole number in a story) is easier than m6-35 and m6-36 that precede it; ids kept. m6-40 and m6-41 find a term number from a value, which is a two-step equation worked backwards, a step ahead of the one-step equations standard but part of the patterns standard.
