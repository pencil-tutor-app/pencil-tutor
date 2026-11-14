# BC Mathematics 8 problem bank (id prefix `m8`, level `middle_school`)

70 original problems in `problems.json`, same format as `shared/problems.json`.
Re-run the checks with `python3 -I verify.py` (exits non-zero on any failure).

## Official source

BC Mathematics 8 curriculum (content + curricular competencies), fetched 2026-11-14:
https://curriculum.gov.bc.ca/curriculum/mathematics/8 (resolves to `/mathematics/8/core`).

Content standards (14), mapped to problem ids:

| # | Content standard | Ids |
|---|---|---|
| S1 | perfect squares and cubes | m8-01 to m8-05 |
| S2 | square and cube roots | m8-06 to m8-10 |
| S3 | percents less than 1 and greater than 100 | m8-11 to m8-15 |
| S4 | numerical proportional reasoning (rates, ratio, proportions, percent; two- and three-term ratios) | m8-16 to m8-20 |
| S5 | operations with fractions, incl. brackets and order of operations (no exponents) | m8-21 to m8-26 |
| S6 | discrete linear relations (tables, expressions, graphs, scaled axes, four quadrants) | m8-27 to m8-31 |
| S7 | expressions: writing and evaluating by substitution | m8-32 to m8-35 |
| S8 | two-step equations, integer coefficients/constants/solutions | m8-36 to m8-41 |
| S9 | surface area and volume of regular solids (prisms incl. triangular, cylinders) | m8-42 to m8-47 |
| S10 | Pythagorean theorem | m8-48 to m8-53 |
| S11 | construction, views and nets of 3D objects | m8-54 to m8-56 (computational versions only) |
| S12 | central tendency (mean, median, mode) | m8-57 to m8-60 |
| S13 | theoretical probability, two independent events | m8-61 to m8-65 |
| S14 | financial literacy: best buys (coupons, unit price, proportional reasoning) | m8-66 to m8-70 |

Each problem's `source` field reads `BC Math 8 content standard S<n> + original`.

## Skipped or reduced

- S11 is mostly drawing and building (matching nets, sketching top/front/side views, design software). Those cannot be
  checked from handwriting, so only 3 computational versions are included (surface area from a net, cube counts and the
  top view, cylinder net dimensions).
- Curricular competencies (puzzles and coding, play and inquiry, First Peoples place-based projects, communicating and
  representing, reflecting) are practices, not written computation. No problems are written for them. The canoe/cedar
  contexts in the content elaborations were not used because they point to projects; one canoe-group cost equation (m8-40)
  keeps a light local flavour.
- Financial literacy: only best buys appears in the Grade 8 standards; no research-style task was included.

## Ontario and Alberta equivalents (closest grade 8 courses)

- Ontario: Mathematics, Grade 8 (2020 curriculum). Strands: number, algebra, data, spatial sense, financial literacy.
  Overview: https://www.ontario.ca/page/math-curriculum-grades-1-8 ; course page
  https://www.dcp.edu.gov.on.ca/en/curriculum/elementary-mathematics/grades/g8-math (the fetched page did not render its
  text, so the topic comparison below is **unverified**, from general knowledge of the 2020 document).
  Likely differences from BC 8: Ontario adds coding strongly in the algebra strand, rational-number and exponent work, and
  a stand-alone financial literacy strand with currency and investing; BC 8 puts perfect squares/cubes, cube roots and
  nets/views in grade 8 while Ontario spreads similar material across grades 7 and 8.
- Alberta: Mathematics, Grade 8. The 2008 program of studies remains the established one
  (https://curriculum.learnalberta.ca/curriculum/en/pos/MAT_79/MATH8); a new draft Grade 8 curriculum, published
  2026-06-18 and open for optional classroom piloting in 2026-27, is at
  https://curriculum.learnalberta.ca/curriculum/en/gfc/MAT_7-9/MAT8 (status: draft, fetched 2026-11-14).
  From search snippets (not read in full, so partly **unverified**): Alberta grade 8 includes perfect squares and square
  roots (whole numbers), nets and surface area of prisms and cylinders, linear equations and slope, and bar graphs/data.
  Likely differences: Alberta 8 has more rational-number operations and slope of linear functions; BC 8 limits work to
  integer linear relations and two-step equations and includes two-event probability and best buys.

## Originality

All 70 problems were written from scratch for this bank from the standards' wording. No problem text, number set or
diagram was taken from textbooks, publisher sites, Studocu, Chegg or provincial exams. The curriculum page's own example
phrases (e.g. a 3 : 5 : 7 string, the square root of 16/169, estimating the square root of 30) were used as topic cues only;
the contexts and numbers were changed or newly built. No student names appear anywhere.

## Verification (2026-11-14)

`verify.py` does two things with exact `fractions.Fraction`, `math`, `statistics` and brute-force enumeration (no
third-party libraries):

1. Per-problem: recomputes each of the 70 answers independently (brute-force equation solving over integers, sample-space
   enumeration for probability, divisor search for factoring, etc.) and requires the answer, plus key intermediate values,
   to appear in `final_answer` / `worked_solution`.
2. Arithmetic scan: every standalone `a op b ... = c` chain in every worked-solution line (96 found after the 2026-11-15 review) is evaluated and
   compared. Lines with brackets, roots, variables or mixed numbers are checked by method 1 instead.

Result at commit time: 70 problems, 0 failures.

Judgment items a human should still glance at: decimal approximations in m8-08, m8-44, m8-45, m8-53 and m8-56 (rounded values
checked mechanically; wording of "to the nearest tenth" is a teaching choice).

## Review (teacher-quality pass, 2026-11-15)

Checked all 70 problems for: one clear answer, grade 8 wording, Canadian/metric context, fit to the BC Math 8 standard,
worked solution one step per line with no skipped steps, final answer matching the ask, difficulty ramp, no names or
recognisable textbook items.

- Reviewed 70, fixed 9, dropped 0, unchanged 61.
- m8-39: prompt showed raw `{x/4}`; now a proper fraction (latex, plain and parts).
- m8-50: US feet replaced by metres (17 m ladder, 8 m out, reaches 15 m); verify.py updated.
- m8-08: "nearest tenth" was argued from 30.25 vs 29.16 only; added the 5.45² = 29.7025 halfway test.
- m8-53: added the 7.3² = 53.29 bound so the choice of 7.2 is shown.
- m8-66: per-mL prices (0.0060 vs 0.0056) replaced by a common 1500 mL comparison ($9.00 vs $8.40), hand-friendly.
- m8-18: proportion was set up but never used; now a single unit-rate method.
- m8-31: added the skipped `−(−3)` step. m8-34: merged a dangling `= −9` line. m8-29: dropped the unneeded "tick marks" clause.
- Most common finding: a skipped or half-used step in the worked solution (5 of 9).
- verify.py: passes (70 problems, 96 chains, 0 failures).
- Unsure: m8-15 ("went up 120%" means 220% of the start; clear to a teacher, but some students read it as 120%);
  m8-69 ends on a non-integer 3.125 months, kept because it is the point of the question.
