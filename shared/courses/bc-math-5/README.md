# BC Mathematics 5 problem bank (Pencil Tutor)

- Official curriculum: https://curriculum.gov.bc.ca/curriculum/mathematics/5 (Content tab: https://curriculum.gov.bc.ca/curriculum/mathematics/5/core), fetched 2026-11-14.
- 90 original problems, ids `m5-01` to `m5-90`, level `elementary`, format identical to `shared/problems.json`.

## Content standards -> problem ids

| # | BC Grade 5 content standard | Problems |
|---|---|---|
| S1 | number concepts to 1 000 000 | m5-01 to m5-06 |
| S2 | decimals to thousandths | m5-07 to m5-10 |
| S3 | equivalent fractions | m5-11 to m5-15 |
| S4 | whole-number, fraction, decimal benchmarks; comparing and ordering fractions and decimals | m5-16 to m5-20 |
| S5 | addition and subtraction of whole numbers to 1 000 000 | m5-21 to m5-25 |
| S6 | multiplication and division to three digits, including remainders | m5-26 to m5-30 |
| S7 | addition and subtraction of decimals to thousandths | m5-31 to m5-35 |
| S8 | addition and subtraction facts to 20 | m5-36 to m5-39 |
| S9 | multiplication and division facts to 100 | m5-40 to m5-44 |
| S10 | rules for increasing and decreasing patterns | m5-45 to m5-49 |
| S11 | one-step equations with variables | m5-50 to m5-54 |
| S12 | area of squares and rectangles; area and perimeter | m5-55 to m5-60 |
| S13 | duration, using measurement of time | m5-61 to m5-65 |
| S14 | classification of prisms and pyramids (incl. quadrilaterals) | m5-66 to m5-70 |
| S15 | single transformations | m5-71 to m5-75 |
| S16 | one-to-one and many-to-one correspondence, double bar graphs | m5-76 to m5-80 |
| S17 | probability experiments, single events | m5-81 to m5-85 |
| S18 | financial literacy: monetary calculations, making change, simple financial plans | m5-86 to m5-90 |

Graph problems (S16) give the data in words because the app has no picture field. S14 `m5-70` (trapezoid) is definition-based.

## Skipped (not hand-written pencil work)

- First Peoples counting systems (Tsimshian, Tlingit) and Elder / knowledge-keeper measuring: discussion and cultural learning, no computation to check.
- Curricular Competencies (reasoning, communicating, connecting, reflecting) and "whole-class number talks": process goals, not content.
- Weaving / cedar-basket transformation designs and traditional dwellings: hands-on projects. Transformations and area/perimeter are covered with coordinate and rectangle versions.
- Financial-literacy research and budgeting discussions: reduced to short computational versions (m5-88 to m5-90).
- Geoboards, tiles, base-10 block manipulatives: physical tools, not paper work.

## Closest Ontario and Alberta grades

- Alberta, Grade 5 Mathematics (new curriculum, implemented Sept 2023): https://curriculum.learnalberta.ca/curriculum/en/gfc/MAT/MAT5 (fetched; learning-outcome titles read directly).
  - Alberta adds: divisibility, improper fractions, fraction add/subtract with common denominators, ratios, numerical and algebraic expressions, symmetry, grid position, arithmetic-sequence terms.
  - Alberta multiplies and divides within 100 000 with standard algorithms and adds/subtracts within 1 000 000 with decimals to thousandths, using standard algorithms (BC allows flexible strategies).
  - BC has that Alberta Grade 5 lacks (from the outcome list): equivalent-fraction benchmarks, elapsed time, prism/pyramid classification, single transformations, single-event probability.
- Ontario, Grade 5 Mathematics (2020 curriculum): https://www.dcp.edu.gov.on.ca/en/curriculum/elementary-mathematics/grades/g5-math. The page loads by script and the fetch returned only the page shell, so the topic comparison below is **unverified**, from general knowledge of the 2020 strands: Ontario Grade 5 also teaches volume, percent, order of operations and coding, and treats decimals to thousandths, fraction operations and transformations in its Number, Algebra, Data, Spatial Sense and Financial Literacy strands.

## Originality

Every problem was written for this bank from the standards text. Nothing was copied from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math), Studocu, Chegg, provincial exams or NonCommercial material. No student names appear anywhere.

## Verification

`python3 -I verify.py` (exit 0 = pass). Run 2026-11-14: 90 problems, 89 mechanically checked, 1 definition-based, 0 failures.

- Each problem carries expected values computed independently in Python (integers, `fractions.Fraction`, `decimal.Decimal`, `datetime` for time, Euler's V - E + F = 2 for solids). The script checks that the stored final answer and key intermediate values match, and that `problems.json` equals what the source in `verify.py` generates.
- Limit: matching is by substring of the written solution, so it confirms the numbers are present and correct, not that every sentence of prose is right. Worked lines were also read by hand.
- `python3 -I verify.py --write` regenerates `problems.json`.
- Re-run after the teacher review, 2026-11-15: 90 problems, 89 mechanically checked, 1 definition-based, 0 failures.

## Review (teacher-quality pass, 2026-11-15)

Checked all 90 problems for: one clear answer, grade-5 wording, Canadian units and spelling, fit with the standard, one-step-per-line worked solutions, answer form, difficulty ramp, duplicates, names. Edits were made in `verify.py` (the source) and `problems.json` regenerated with `--write`.

- Reviewed 90, fixed 14, dropped 0, unchanged 76.
- Fixed: m5-74 (the old prompt, one point moving (6, 2) to (2, 2), was ambiguous: a flip over x = 4 or a half turn gives the same image; now a whole triangle with "not flipped or turned"); m5-84 (said "the same bag" from another problem, now stands alone); m5-90 (near-copy of m5-86, now a two-item purchase); m5-80 (odd "9 stars' worth" wording and unused Ella data, now uses both rows); m5-78 ("double bar graph" with one bar per day, now "bar graph"); m5-20, m5-22, m5-32, m5-34 (worked lines that jumped steps or read like prose); m5-26 and m5-27 swapped so the easier multiplication comes first (ids stay with their slot, so the content under those two ids changed places); m5-81 to m5-84 (P(...) notation replaced by "probability of ...", which grade 5 has not met).
- Most common problem: a worked line that skipped the step a student would need to write, or hid the work in a "do it all" sentence.
- Unsure: m5-70 (trapezoid with exactly one pair of parallel sides) follows the exclusive definition stated in the prompt; BC Grade 5 does not say which definition to use. Only reflections over vertical and horizontal lines are used in S15, no rotation about a point. S8 and S9 contain a few very easy problems (m5-38, m5-42); kept because they are fact-fluency checks.
