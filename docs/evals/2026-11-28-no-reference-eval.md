# No-reference eval: can the tutor check a problem it has no answer key for? 2026-11-28

Plain words first; the official term once where it helps.

**Short answer.** When the student types their own problem the tutor has no worked solution and no final answer, so it has to solve the problem itself. Two models were tried on the 84 clean course pages and on 13 real pages of Edward's handwriting. Neither raised a false alarm on any real page (0 of 13 each), and neither failed or errored once. On the course pages the larger model (`gpt-6.1-sol`) caught the planted mistake on the right line 40 of 42 times and was never silent; the small model (`gpt-6-luna`) caught 38 of 42 and stayed silent on 2. Every false alarm and every wrong-line result, for both models, sits on 4 pages where the typed statement does not match what the picture shows (a defect in 2 of the fixtures, below); luna's 2 silences are on pages with a matching statement. By the rule in the order (fewer false alarms first, then more caught, tie to the cheaper) the false alarms tie, so the larger model wins and `OWN_PROBLEM_LEVEL` is `advanced`. It costs about 17 times more per look. The numbers are small and the real pages contain no real mistake; read the limits.

## What was run

- Code: branch `own-problem` (off `main` fd5d816) with the step 1 server changes and the eval changes of this step, uncommitted at the time. The harness drives the real `handleWatch` and `handleConsult` (`server/lib/watch.ts`, `server/lib/consult.ts`), so the own-problem resolver (`server/lib/problems.ts:66`), the no-reference prompt (`server/lib/policy.ts:88`, `NO_REFERENCE_NOTE`), the page picture handling, the schema and the line check are the production ones.
- `--no-reference` (`server/eval/run-eval.ts:41`, `problemFor` at line 89): every page is sent as `own:<its course>` with `problem_text` = the bank problem's `prompt_plain`. No worked solution, no final answer reaches the model.
- Which model really ran (the review's trap): the handler reads `WATCH_MODEL` for the high school level and `WATCH_MODEL_ADVANCED` for the advanced one, and an own problem may resolve to either, so `envFor` (`run-eval.ts:73`) now sets provider, model and effort for both levels, for watch and ask. Each row records the model and level the handler actually used (`row.model`, `row.level`, `run-eval.ts:188`), and `score.ts` counts a row whose model differs from the candidate's name (the "other model ran" column). Result: 0 of 207 rows ran another model. Every watch and consult row in this eval ran at level `high_school`, because the constant was still `high_school` while the runs were made; the candidate named was the model that answered (checked in each row). After the choice the constant became `advanced`, and the same `envFor` sets the advanced variables, so the chosen model runs unchanged.
- Reasoning effort: none set (the provider default), as production does. No database (in-memory student store). Keys were loaded exec-only with `tsx --env-file=<a local env file outside this repo>`, never printed or saved.
- Calls: 207 saved rows plus 13 judge calls for the consult rows = 220 model calls, the cap. `--max-calls` held each run to its rows. The SDK allows one retry on transport errors and retries are not visible in the rows.

| run (file in `server/eval/results/`) | pages | models | rows |
|---|---|---|---|
| `no-reference-courses-2026-11-28` | 84 clean course pages (42 correct, 42 with one planted mistake) | luna, sol | 168 |
| `no-reference-real-pages-2026-11-28` | 13 real correct pages | luna, sol | 26 |
| `no-reference-consult-real-2026-11-28` | 7 of the 13 real pages, "check my work" through consult | sol | 7 |
| `no-reference-consult-courses-2026-11-28` | 6 planted-mistake course pages, consult | sol | 6 |

## Results

Watch, 84 clean course pages, both models answered all 84 (0 errors, 0 schema failures, 0 server downgrades):

| model | caught on the right line | wrong line | silent | false alarms (of 42 correct) | cost per look | p50 | p90 |
|---|---|---|---|---|---|---|---|
| gpt-6.1-sol | 40 / 42 | 2 | 0 | 2 | $0.00437 | 4.3 s | 5.8 s |
| gpt-6-luna | 38 / 42 | 2 | 2 | 2 | $0.00026 | 2.9 s | 3.8 s |

**The 4 pages that explain every false alarm and every wrong line.** `m5-26` and `fm11-39` are fixture defects: the page picture does not match the bank statement. `m5-26` is typed as "Find 237 × 4." but the picture works 36 × 24; `fm11-39` is typed as six pages-read counts (11, 12, 14, 15, ...) but the picture computes a mean of 2, 4, 4, 4, 5, 5, 7, 9. Found by comparing the numbers of each bank statement with the numbers on each page's rows (`server/eval/fixtures/courses/manifest.json`): these 2 of 42 problems differ, so 4 of 84 pages. Both models flagged line 1 on all 4 pages ("the numbers do not match the problem"), which is the right answer to a mismatch but scores as a false alarm on the 2 correct pages and a wrong line on the 2 planted pages. Without those 4 pages:

| model | caught | wrong line | silent | false alarms |
|---|---|---|---|---|
| gpt-6.1-sol | 40 / 40 | 0 | 0 | 0 / 40 |
| gpt-6-luna | 38 / 40 | 0 | 2 | 0 / 40 |

Luna's two silences are `bc-math-5__m5-33__wrong-w4` ("the decimal addition is correct") and `bc-calc-12__ca12-28__wrong-w3` (called the quotient rule right). Sol caught both. The reference-based eval of 2026-11-15 used the same bank statements and so also ran those 4 pages against a reference that does not match the picture (a lead, not re-run here).

Watch, 13 real correct pages (Edward's handwriting, session `2026-11-14T11-00-54`, typed statement `7x - 4 = 3x + 16`, course `bc-math-9`):

| model | false alarms | silent / caught | errors | cost per look |
|---|---|---|---|---|
| gpt-6.1-sol | 0 / 13 | n/a (all pages correct) | 0 | $0.00354 |
| gpt-6-luna | 0 / 13 | n/a | 0 | $0.00030 |

The stated reasons were about the right thing in all 26 (for example "Line 2 correctly subtracts 3x from both sides", "the last line is unfinished with an empty right side"), so the waits are not an always-silent habit. For comparison, production's own luna, with the reference, waited on all 13 of these looks in the original session (`decision` events of that session log).

Consult ("Can you check my work so far? Is it right?"), Sol only, judged by the harness's report judge:

| pages | result |
|---|---|
| 7 real correct pages | 0 / 7 report an error, 0 leaks of the answer |
| 6 planted-mistake course pages (including the 2 luna missed in watch) | 6 / 6 name the right line, 0 leaks |

Hint leak check on watch: for the 86 interrupts in the course run, no spoken or written hint contained the bank problem's final answer (post-hoc check against the bank, which the model never saw).

## Choosing the tier

Rule from the order: fewer false alarms first, then more caught on the right line, judged together with failures; a tie goes to the cheaper.

- False alarms: tie, on the course pages (2 and 2, the same 2 pages) and on the real pages (0 and 0).
- Failures and errors: tie, 0 each.
- Not an always-waiting winner: luna is the one that waited on 2 planted mistakes; sol waited on none.
- Caught on the right line: sol 40 vs luna 38 of 42.

So `OWN_PROBLEM_LEVEL = "advanced"` (`server/lib/problems.ts:49`): `gpt-6.1-sol` for watch, ask and consult on own problems unless `WATCH_MODEL_ADVANCED` or `ASK_MODEL_ADVANCED` are set otherwise. After a deploy, `/api/health` field `models_advanced` shows what that resolves to.

## Cost (estimated from the usage the API returned)

Each row's cost is the handler's own estimate from the token counts the API returned, priced by `server/lib/pricing.ts` (`cost_basis: estimated`; an estimate, not a bill). Whole eval: models $0.497 + judge $0.017 = about $0.51 for 220 calls.

| | input tokens per look | output (incl. reasoning) per look | cost per look |
|---|---|---|---|
| sol watch | about 1,760 | 85 on course pages (27 reasoning) | $0.0044 |
| luna watch | about 1,760 | 164 (112 reasoning) | $0.00026 |
| sol consult | about 1,200 | 200 to 260 | $0.0040 to $0.0051 |

Sol is about 17 times luna per watch look. With the 3 minute device session's mix of 7 watch and 6 question looks (`score.ts` `perMinute`) that is roughly $0.018 per working minute, about $1.1 per working hour, for an own problem on Sol, against about $0.04 per hour for luna watch looks alone. Bank problems stay on luna. The 8 hour monthly cap makes the worst case about $9 per student per month if every minute were an own problem (an estimate from 13 consult looks and 168 watch looks).

## Limits

- The course pages are synthetic handwriting in clean fonts, one planted mistake each, 3 problems per course, one run per model (no repeats, so the variance is unknown). 40 vs 38 is a 2 page difference.
- The 13 real pages are one student, one problem, one session, mostly mid-work, and 12 are distinct (w12 and w13 are the identical picture). They contain no real mistake: they measure false alarms only. How well the tutor catches a mistake in real handwriting with no reference is NOT measured.
- Line boxes for the real pages: the app's real boxes were not kept. The harness sends `lines` with a box per margin number; I used the number of lines the app sent (from that session's `look_started` events), put each line's box at the height of the margin number drawn on the picture (read by eye), and gave every box the same nominal size (x 340, 440 wide, 50 tall). Indexes and count are what the app sent; box sizes are not. The page set lives outside the repo (symlinks to the pictures in the session scratch folder), and the pictures are not in this repo.
- The real pages were typed as `7x - 4 = 3x + 16` with ASCII characters. The bank uses a real minus sign; a student's keyboard sends a hyphen.
- Consult was run for sol only, on 13 looks. Ask (speech to text first) was not run: it needs recorded audio. It shares `referenceBlock`, the model and the level code with consult, and a unit test checks that the ask prompt carries the no-reference note, but ask accuracy on own problems is unmeasured, and so is consult on luna.
- Nothing on the server can detect a hint that states the answer for an own problem (no answer to compare with); the 86-interrupt leak check above is post-hoc and only covers the course pages.
- Prices are the table in `pricing.ts`; the estimate can be off if a vendor changed a price.

## Rerun

```sh
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-eval.ts --models openai:gpt-6-luna,openai:gpt-6.1-sol \
  --roles watch --fixtures courses --no-reference --run no-reference-courses --max-calls 168
tsx server/eval/score.ts server/eval/results/no-reference-courses.jsonl server/eval/fixtures/courses/manifest.json
```

For real pages kept outside the repo, `--fixtures-dir <absolute folder>` takes a `manifest.json` plus the pictures; an entry may carry `own_problem: {course, text}`.
