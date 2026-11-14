# BC Pre-calculus 12: problem bank (`pc12`)

84 original problems for Pencil Tutor, level `high_school`, in the format of `shared/problems.json`.

## Official curriculum

- Content standards (retrieved 2026-11-14): https://curriculum.gov.bc.ca/curriculum/mathematics/12/pre-calculus
- Elaborations PDF (listed by the same site): https://curriculum.gov.bc.ca/sites/curriculum.gov.bc.ca/files/curriculum/mathematics/en_mathematics_12_pre-calculus_elab.pdf

Full list of Content standards, copied from the page:

1. transformations of functions and relations: graphs and equations of parent functions and relations (absolute value, radical, reciprocal, conics, exponential, logarithmic, trigonometric); vertical and horizontal translations, stretches, reflections; inverses (graphs and equations); extension: recognizing composed functions, operations on functions
2. exponential functions and equations: graphing, including transformations; solving equations with same base and with different bases, including base e; solving problems in situational contexts
3. geometric sequences and series: common ratio, first term, general term; geometric sequences connecting to exponential functions; infinite geometric series; sigma notation
4. logarithms: operations, functions, and equations: applying laws of logarithms; evaluating with different bases; using common and natural logarithms; exploring inverse of exponential; graphing, including transformations; solving equations with same base and with different bases; solving problems in situational contexts
5. polynomial functions and equations: factoring, including the factor theorem and the remainder theorem; graphing and the characteristics of a graph (degree, extrema, zeros, end behaviour); solving equations algebraically and graphically
6. rational functions: characteristics of graphs, including asymptotes, intercepts, point discontinuities, domain, end behaviour
7. trigonometry: functions, equations, and identities: angles in standard position in both radians and degrees; unit circle, reference and coterminal angles, special angles; graphing primary trigonometric functions, including transformations and characteristics; solving first and second degree equations (restricted domains and all real numbers); solving problems in situational contexts; identities (Pythagorean, quotient, double angle, reciprocal, sum and difference)

For this bank the seven headings were split into 15 groups so each group gets 4 to 7 problems.

## Standard to problem ids

| Content standard (as written in this bank) | Count | Problem ids |
|---|---|---|
| BC Pre-calculus 12 content: transformations of functions and relations (parent functions; vertical and horizontal translations, stretches, reflections) | 5 | pc12-01 to pc12-05 |
| BC Pre-calculus 12 content: transformations (inverses: graphs and equations) | 4 | pc12-06 to pc12-09 |
| BC Pre-calculus 12 content: transformations extension (composed functions, operations on functions) | 4 | pc12-10 to pc12-13 |
| BC Pre-calculus 12 content: exponential functions and equations (graphing, including transformations) | 4 | pc12-14 to pc12-17 |
| BC Pre-calculus 12 content: exponential functions and equations (solving same-base and different-base equations incl. base e; situational problems) | 6 | pc12-18 to pc12-23 |
| BC Pre-calculus 12 content: geometric sequences and series (common ratio, general term, infinite series, sigma notation) | 6 | pc12-24 to pc12-29 |
| BC Pre-calculus 12 content: logarithms (laws of logarithms, different bases, common and natural logarithms, inverse of exponential) | 6 | pc12-30 to pc12-35 |
| BC Pre-calculus 12 content: logarithms (graphing, solving equations, situational problems) | 7 | pc12-36 to pc12-42 |
| BC Pre-calculus 12 content: polynomial functions and equations (factoring, factor theorem, remainder theorem) | 6 | pc12-43 to pc12-48 |
| BC Pre-calculus 12 content: polynomial functions and equations (graph characteristics; solving algebraically and graphically) | 5 | pc12-49 to pc12-53 |
| BC Pre-calculus 12 content: rational functions (asymptotes, intercepts, point discontinuities, domain, end behaviour) | 6 | pc12-54 to pc12-59 |
| BC Pre-calculus 12 content: trigonometry (angles in standard position in radians and degrees, unit circle, reference and coterminal angles, special angles) | 6 | pc12-60 to pc12-65 |
| BC Pre-calculus 12 content: trigonometry (graphing primary trigonometric functions, transformations and characteristics) | 5 | pc12-66 to pc12-70 |
| BC Pre-calculus 12 content: trigonometry (solving first and second degree equations; situational problems) | 8 | pc12-71 to pc12-78 |
| BC Pre-calculus 12 content: trigonometry (identities: Pythagorean, quotient, double angle, reciprocal, sum and difference) | 6 | pc12-79 to pc12-84 |

## Skipped standards

None skipped. The "conics" parent function mention in standard 1 (and "extrema"/graphing by technology wording) is covered only through the function families listed above; conics belong to Foundations of Mathematics 12 in this project. The Curricular Competencies (reasoning, communicating, reflecting, First Peoples perspectives) are not content and have no written-work problems.

## Ontario and Alberta equivalents (closest courses)

| BC course content | Ontario | Alberta |
|---|---|---|
| Pre-calculus 12 | Advanced Functions, Grade 12, University (MHF4U). Official course list: https://www.dcp.edu.gov.on.ca/en/curriculum/secondary-mathematics/courses-list ; descriptions and prerequisites: https://www.dcp.edu.gov.on.ca/en/course-descriptions-and-prerequisites/mathematics | Mathematics 30-1. Program of studies: https://curriculum.learnalberta.ca/curriculum/en/pos/MAT_HS/MAT3791 ; diploma bulletin: https://alberta.ca/system/files/custom_downloaded_images/edc-math-30-1-info-bulletin.pdf |

Topic differences (read from the Ontario course description wording, the Alberta bulletin headings and the BC list above; the line-by-line comparison is **unverified**, because the Ontario and Alberta program documents themselves were not fully read):

- Ontario MHF4U covers polynomial, rational, logarithmic and trigonometric functions plus rates of change in the same course (the Ontario description says it also develops ideas of rates of change), so it leans toward a calculus lead-in that BC puts in Calculus 12.
- Alberta Math 30-1 groups the content as Relations and Functions, Trigonometry, and Permutations, Combinations and Binomial Theorem (headings in the 2025-2026 bulletin). Counting/probability that BC places in Foundations 12 sits in Alberta 30-1, and BC's geometric sequences and series appear in BC Pre-calculus 12 but are not named in the Alberta bulletin headings (unverified whether they appear in the Alberta program of studies).
- Radians and degrees, unit circle, identities, polynomial and rational functions, exponential and logarithm laws: all three provinces teach these in the Grade 12 university-bound stream.

## Originality statement

Every prompt, worked solution and number in this bank was written from scratch for this project. Nothing was copied or adapted from textbooks (Pearson, McGraw-Hill, Math Makes Sense, MathFocus, Jump Math and similar), from Studocu or Chegg, or from provincial exams. Numbers were chosen for clean by-hand work. No student names appear anywhere.

## Verification (2026-11-14)

`verify.py` is both the spec and the checker, standard library only (`fractions`, `math`, brute force). Run from this folder:

```
python3 -I verify.py            # re-check problems.json against the spec and re-run every maths check
python3 -I verify.py --write    # regenerate problems.json from the spec
```

Each problem has a check function that recomputes the result independently: brute-force root searches over rationals, polynomial multiplication and long division with exact fractions, numeric identity tests at several points for inverses, compositions and trig identities, direct search of angle grids for trig equations, and exact `Fraction` arithmetic for series and rational equations. Where the answer is an exact closed form (such as a surd), the check proves the numeric value matches the closed form; the printed string is typed in the check and compared with `final_answer`. The script fails (exit 1) if any check fails, if the ids are not unique, or if `problems.json` differs from the spec.

Result on 2026-11-14: 84 of 84 problems verified, 0 failures.

Not verified mechanically: the wording of the worked steps (read by hand against the checked answers), and the Ontario/Alberta topic comparison above.
