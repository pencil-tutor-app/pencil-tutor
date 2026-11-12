# Pencil Tutor server

(Full README follows once the endpoints land. This section is committed first because the iPad app reads the problem bank.)

## Problem bank: `shared/problems.json`

A JSON array of 12 equation problems from BC Math 9 unit 3, each paired by hand with its worked solution. Fields:

| field | meaning |
|---|---|
| `id` | `u3-NN`, NN is the problem number in `extra-practice.md` |
| `source` | where it came from, for humans |
| `prompt_latex` | the original LaTeX (not rendered on device) |
| `prompt_plain` | readable one-line text, e.g. `2k/5 − 3 = 1` (real minus sign U+2212) |
| `prompt_parts` | what the iPad draws, left to right |
| `worked_solution` | array of plain-text lines, one step each |
| `final_answer` | e.g. `k = 10` |

`prompt_parts` is a list of items, each exactly one of:

- `{ "text": "7x − 4 = 3x + 16" }` draw as ordinary text
- `{ "frac": { "num": "2k", "den": "5" } }` draw as a stacked fraction (numerator over a bar over denominator)

Draw the parts in order on one baseline-aligned row. Example, `(2/3)(x − 1) = (1/2)(x + 3)`:
`frac(2,3)`, text `(x − 1) = `, `frac(1,2)`, text `(x + 3)`. Numerator and denominator are plain text and may contain spaces and operators (`x + 4`). Fractions never nest.

The iPad shows only the prompt. `worked_solution` and `final_answer` stay on the server side as the tutor's reference (the server loads this same file).
