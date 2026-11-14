# Linear Algebra problem bank (college track)

69 original problems, `la-01` to `la-69`, in `problems.json`, in the same format as `shared/problems.json`
(`id`, `source`, `prompt_latex`, `prompt_plain`, `prompt_parts`, `worked_solution[]`, `final_answer`, `level`).
`level` is `"college"`. `source` is the topic name plus `, original`. The course is not wired into the app yet.

## Outline source

Douglas College, **MATH 2232 Linear Algebra** (3 credits, prerequisite MATH 1120 or MATH 1130).
https://douglascollege.ca/course/math-2232 (course guidelines, current version September 2020; fetched 2026-11-14).

Course content list, in the official order:

1. Solving Systems of Equations
2. The Algebra of Matrices
3. Determinants
4. The Vector Space Rn
5. Vector Geometry
6. General Vector Spaces
7. Inner Product Spaces
8. Linear Transformations and Linear Operators
9. Eigenvalues and Diagonalisation

The bank follows the learning outcomes under each heading (Gauss-Jordan, inverses, adjoint and Cramer's Rule, subspaces,
span, independence, basis, rank, dot and cross product, lines and planes, P2 and M22, inner products, Gram-Schmidt,
standard matrices, kernel and range, transition matrices, eigenvalues, diagonalisation, A^n = P D^n P^-1).

## Topic to problem map

| # | Topic | Problems | Count |
|---|-------|----------|-------|
| 1 | Solving Systems of Equations | la-01 to la-06 | 6 |
| 2 | The Algebra of Matrices | la-07 to la-13 | 7 |
| 3 | Determinants | la-14 to la-21 | 8 |
| 4 | The Vector Space Rn | la-22 to la-29 | 8 |
| 5 | Vector Geometry | la-30 to la-38 | 9 |
| 6 | General Vector Spaces (P2, M22) | la-39 to la-45 | 7 |
| 7 | Inner Product Spaces | la-46 to la-50 | 5 |
| 8 | Linear Transformations and Linear Operators | la-51 to la-60 | 10 |
| 9 | Eigenvalues and Diagonalisation | la-61 to la-69 | 9 |

Within each topic the problems run easy to hard. Detail:

- Systems: la-01 two unknowns, la-02 Gaussian, la-03 Gauss-Jordan, la-04 inconsistent, la-05 free variable, la-06 parameter k.
- Matrices: la-07 product and non-commutativity, la-08 transpose of a product, la-09 and la-10 inverse by Gauss-Jordan (2x2, 3x3), la-11 solve with the inverse, la-12 matrix equation, la-13 (A+B)^2.
- Determinants: la-14 singular value, la-15 cofactors, la-16 row reduction, la-17 properties, la-18 adjoint inverse, la-19 and la-20 Cramer, la-21 parameter.
- Rn: la-22 and la-23 subspace test, la-24 combination, la-25 span, la-26 independence, la-27 basis, la-28 rank/column/row space, la-29 null space.
- Vector geometry: la-30 angle, la-31 orthogonality, la-32 projection, la-33 orthogonal complement of a vector, la-34 cross product area, la-35 plane through 3 points, la-36 point-plane distance, la-37 point-line distance, la-38 line forms and line-plane intersection.
- General vector spaces: la-39 and la-40 P2 subspaces, la-41 and la-42 M22 subspaces, la-43 P2 independence, la-44 M22 basis test, la-45 coordinates.
- Inner products: la-46 on P2, la-47 on M22, la-48 and la-49 Gram-Schmidt (2 and 3 vectors), la-50 orthogonal projection onto a subspace.
- Transformations: la-51 prove linear, la-52 disprove, la-53 standard matrix, la-54 composition, la-55 rotation then reflection, la-56 kernel/range/rank-nullity, la-57 one-to-one, la-58 transition matrix, la-59 matrix relative to a basis, la-60 derivative P2 to P1.
- Eigen: la-61 characteristic polynomial, la-62 eigenspaces, la-63 defective matrix, la-64 3x3 repeated eigenvalue, la-65 diagonalise, la-66 A^5, la-67 similar matrices, la-68 eigenvalues of A^2, A^-1, A+4I, la-69 Markov steady state.

Not covered (listed on the outline as optional, or one-off): LU factorisation, least squares, recurrence equations,
volume of a parallelepiped, shear and dilation identification, isomorphism, Cauchy-Schwarz and the triangle inequality,
electrical networks and traffic flow.

## Notation used in the prompts and solutions

Matrices are written row by row with `;` between rows: `[1 2; 3 4]` has rows (1, 2) and (3, 4). Vectors are tuples
`(1, 2, 3)`. Augmented matrices use a bar: `[1 2 | 5; 3 4 | 6]`. Row operations read `R2 → R2 − 2R1`.
Plain text uses Unicode math (−, ·, ², ⁻¹, ᵀ, √, λ).

## Equivalent first courses at other BC universities

| Institution | Course | URL |
|-------------|--------|-----|
| SFU | MATH 240 Algebra I: Linear Algebra (3). Douglas MATH 2232 transfers to SFU MATH 240 per the Douglas transfer table. | https://www.sfu.ca/students/calendar/2026/fall/courses/math/240.html |
| UBC Vancouver | MATH_V 221 Matrix Algebra (3). The Douglas transfer table lists the UBCV credit for MATH 2232 as MATH_V 111 (3), which is a transfer-credit label and not the UBC course a student takes next; MATH_V 221 is UBC's own matrix algebra course. | https://vancouver.calendar.ubc.ca/course-descriptions/courses/mathv-221-matrix-algebra |

## Licence statement

All 69 problems, prompts, worked solutions and numbers were written from scratch for Pencil Tutor. Nothing was copied or
adapted from any textbook, Studocu, Chegg or a past exam. The Douglas College outline was used only for the topic list.
No NonCommercial-licensed material (for example OpenStax) was consulted.

## Verification

`verify.py` is the verification script. Run it with `python3 -I shared/courses/linear-algebra/verify.py` (needs `sympy`).

Each problem has its own check function. The check recomputes the answer and every intermediate result with sympy
(row operations are replayed one at a time; determinants, inverses, nullspaces, eigenvalues, projections and
Gram-Schmidt are recomputed independently; proofs are checked by symbolic expansion). The check then returns the facts
it computed, written in the same notation as the solution, and the runner confirms each one appears in the problem's
`prompt_plain`, `worked_solution` or `final_answer`. It also checks the schema: key order, `level`, `source`, and 2 to 12
solution lines per problem.

Result on 2026-11-14: 69 of 69 verified, 0 failed. The runner was also tested against deliberately corrupted copies
(a wrong z in la-02, a wrong adjugate entry in la-18, a wrong final matrix in la-66); it flagged all three.

Not machine-checked: the prose in the solution lines (wording of the reasoning, "so the system is inconsistent"), and
how well the first-wrong-line comparison works for these solutions in the tutor. Numbers and matrices are checked; the
English connecting them is not.

## Review

Teacher-quality review, 2026-11-15. Every one of the 69 problems was read for: one unambiguous answer, standard college wording, fit with MATH 2232, one-step-per-line solutions, `final_answer` matching the prompt, difficulty order within each topic, and no real names or recognisable textbook problems. The matrix products, row operations, determinants and eigenvectors in the solutions were re-derived by hand.

| outcome | count | ids |
|---|---|---|
| reviewed | 69 | all |
| fixed | 5 | la-18, la-29, la-30, la-38, la-63 |
| dropped | 0 | none |
| unchanged | 64 | the rest |

What was fixed: la-18 showed only 3 of the 9 cofactors, now all 9 are worked (row by row) before the cofactor matrix; la-29 used x, y, z, w in the solution though the prompt names no variables, now x₁ to x₄ (the expected text in `verify.py` was updated to match); la-30 did not say degrees; la-38 asked for parametric and symmetric equations plus the intersection but `final_answer` held only the point, now all three; la-63 counted eigenvectors in one unexplained sentence, now says which eigenvalue each comes from. No numeric answer changed.

Unsure: spelling uses "-ise" (diagonalisable, normalised) as the outline does; Canadian usage also accepts "-ize". Left as is.

Verification re-run 2026-11-15 with sympy 1.14.0: `problems in file: 69   verified: 69   failed: 0`.
