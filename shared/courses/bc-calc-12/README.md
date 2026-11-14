# BC Calculus 12: problem bank (`ca12`)

77 original problems for Pencil Tutor, level `high_school`, in the format of `shared/problems.json`.

## Official curriculum

- Content standards (retrieved 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/12/calculus
- Elaborations PDF (same site): https://curriculum.gov.bc.ca/sites/curriculum.gov.bc.ca/files/curriculum/mathematics/en_mathematics_12_calculus_elab.pdf (June 2018)

Full list of Content standards, copied from the page (elaborations in brackets from the PDF):

1. functions and graphs [parent functions from Pre-calculus 12; piecewise functions; inverse trigonometric functions]
2. limits: left and right limits; limits to infinity; continuity [from a table of values, graphically and algebraically; one-sided versus two-sided; end behaviour; intermediate value theorem]
3. differentiation: rate of change; differentiation rules; higher order, implicit; applications (differentiation) [definition of derivative, notation; average versus instantaneous rate, secant and tangent slopes; power, product, quotient and chain rules; logarithmic, exponential and trigonometric derivatives; graphs of f, f' and f'', increasing/decreasing, concavity; differentiability, mean value theorem; Newton's method; related rates and optimization]
4. integration: approximations; fundamental theorem of calculus; methods of integration; applications (integration) [Riemann sum, rectangle approximation method, trapezoidal method; antiderivatives; substitution; by parts; area under a curve, volume of solids, average value of functions; differential equations, initial value problems, slope fields]

The four headings were split into 16 groups so each group gets 3 to 7 problems.

## Standard to problem ids

| Content standard (as written in this bank) | Count | Problem ids |
|---|---|---|
| BC Calculus 12 content: functions and graphs (parent functions from Pre-calculus 12, piecewise functions, inverse trigonometric functions) | 5 | ca12-01 to ca12-05 |
| BC Calculus 12 content: limits (from a table, graphically and algebraically; one-sided versus two-sided) | 6 | ca12-06 to ca12-11 |
| BC Calculus 12 content: limits to infinity (end behaviour, horizontal and vertical asymptotes) | 5 | ca12-12 to ca12-16 |
| BC Calculus 12 content: continuity (including the intermediate value theorem) | 4 | ca12-17 to ca12-20 |
| BC Calculus 12 content: differentiation, rate of change (average versus instantaneous, definition of the derivative, notation, secant and tangent slopes) | 5 | ca12-21 to ca12-25 |
| BC Calculus 12 content: differentiation rules (power, product, quotient and chain) | 6 | ca12-26 to ca12-31 |
| BC Calculus 12 content: differentiation rules for transcendental functions (logarithmic, exponential, trigonometric) | 6 | ca12-32 to ca12-37 |
| BC Calculus 12 content: differentiation, higher order and implicit | 4 | ca12-38 to ca12-41 |
| BC Calculus 12 content: applications of differentiation (graph of f, f' and f'', increasing and decreasing, concavity, mean value theorem, Newton's method) | 5 | ca12-42 to ca12-46 |
| BC Calculus 12 content: applications of differentiation (related rates) | 3 | ca12-47 to ca12-49 |
| BC Calculus 12 content: applications of differentiation (optimization) | 4 | ca12-50 to ca12-53 |
| BC Calculus 12 content: integration, approximations (Riemann sums, rectangle and trapezoidal methods) | 4 | ca12-54 to ca12-57 |
| BC Calculus 12 content: integration (antiderivatives, definite and indefinite integrals, fundamental theorem of calculus) | 5 | ca12-58 to ca12-62 |
| BC Calculus 12 content: methods of integration (substitution, integration by parts) | 6 | ca12-63 to ca12-68 |
| BC Calculus 12 content: applications of integration (area under and between curves, volume of solids, average value) | 5 | ca12-69 to ca12-73 |
| BC Calculus 12 content: applications of integration (differential equations, initial value problems, slope fields) | 4 | ca12-74 to ca12-77 |

## Skipped or reduced standards

- "history" of differentiation (elaboration for the definition of the derivative): not written work, skipped.
- Differentiability as a topic (corners, cusps) has no separate problem: the one sided limit and piecewise problems (`ca12-06` to `ca12-11`, `ca12-01`, `ca12-04`) cover the underlying ideas, and the mean value theorem problem covers the hypothesis check.
- Slope fields: only the numerical half (reading slopes from dy/dx = f(x, y)) is a written computation; the drawing itself is not asked.
- Volume of solids: disc and washer methods only; shells and cross section volumes are not covered.
- Curricular Competencies (reasoning, communicating, reflecting, First Peoples perspectives) are not content and have no written-work problems.

## Ontario and Alberta equivalents (closest courses)

| BC course content | Ontario | Alberta |
|---|---|---|
| Calculus 12 | Calculus and Vectors, Grade 12, University (MCV4U). Course list: https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses-list ; prerequisites: https://www.dcp.edu.gov.on.ca/en/course-descriptions-and-prerequisites/mathematics (MHF4U Advanced Functions must be taken before or with MCV4U) | Mathematics 31 (calculus). Program of studies: https://curriculum.learnalberta.ca/curriculum/en/pos/MATCAL ; curriculum guide: https://open.alberta.ca/publications/curriculum-guide-for-mathematics-31-0163300199060 |

Topic differences (**unverified line by line**; based on course descriptions and outlines surfaced in search, not on the full program documents):

- Ontario MCV4U pairs derivatives with vectors, lines and planes in 3-D. Its published outline (TDSB, https://schoolweb.tdsb.on.ca/Portals/johnamacdonald/docs/Course%20Outlines/Math/MCV4U.pdf) lists vectors, lines and planes, rates of change, derivatives of exponential and trigonometric functions and later units; the units I saw did not include integration. BC Calculus 12 has no vectors and does include integration (approximation, FTC, substitution, parts, volumes, differential equations).
- Alberta Math 31 is a calculus-only course. The program of studies text says it builds on functions and "expands this knowledge to include a study of limits in preparation for a study of differential and integral calculus" and mentions integration as accumulation; whether it reaches integration by parts, volumes or slope fields could not be confirmed.

## Originality statement

Every prompt, worked solution and number in this bank was written from scratch for this project. Nothing was copied or adapted from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math and similar), from Studocu or Chegg, or from provincial exams. Numbers were chosen for clean by-hand work. No student names appear anywhere.

## Verification (2026-11-14)

`verify.py` is both the spec and the checker, standard library only. Run from this folder:

```
python3 -I verify.py            # re-check problems.json against the spec and re-run every maths check
python3 -I verify.py --write    # regenerate problems.json from the spec
```

Each problem has a check that recomputes the result independently. Limits are evaluated numerically from both sides (h = 1e-6 or 1e-7) and at large x; derivatives are checked against a central difference at several points; antiderivatives are checked by differentiating them; definite integrals, areas, volumes and averages are checked by Simpson's rule (2000 or more intervals); Newton, Riemann, midpoint and trapezoid sums use exact `Fraction` arithmetic; optimization answers are checked by scanning candidates. Closed forms (surds, e, pi) are proved equal to the numeric value, and the printed string typed in the check is compared with `final_answer`. The script exits 1 if any check fails, if ids repeat, or if `problems.json` differs from the spec. As a sanity test of the checker, three deliberately wrong constants were planted in a scratch copy and all three were reported as failures.

Result on 2026-11-14: 77 of 77 problems verified, 0 failures.

Not verified mechanically: the wording of worked steps (read by hand), the Ontario/Alberta comparison above.

## Review (2026-11-15)

Teacher-quality read of all 77 problems against seven checks: one unambiguous answer, age-appropriate wording, fit to BC Calculus 12, worked solution reads like a student's lines with no skipped step, final answer matches the request, difficulty ramp inside each group, no names or recognisable textbook problems.

- Reviewed 77, fixed 7, dropped 0, unchanged 70. No final answer changed in value; `python3 -I verify.py` passes 77 of 77.
- Fixed: `ca12-06` (table values now show the arithmetic), `ca12-15` (the x < 0 side is now explained as a student would write it), `ca12-23` and `ca12-41` (a skipped algebra line written out), `ca12-26` (the answer was printed with the odd character x⁻½, now x^(−1/2)), `ca12-24` and `ca12-63` (the words "Point-slope" and "Back-substitute" were printed with a minus sign instead of a hyphen because the minus-sign helper in `verify.py` rewrote every hyphen; the helper now keeps hyphens between two letters on each side).
- Most common problem: a worked solution that skips one algebra line, then typography.
- Unsure: ramp order in two groups is not strictly easy to hard (`ca12-61` before `ca12-62`; `ca12-74` before `ca12-75`); ids are stable so the order was left. The limit problems print "limit as x → a of ..." in prose, which is clear on screen; a proper lim notation would need app support.
