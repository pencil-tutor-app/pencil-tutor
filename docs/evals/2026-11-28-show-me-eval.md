# Show me how: one real-model pass on the hard cases and the routing (2026-11-28)

Scope: decision 4 of `docs/show-me-plan.md` (Revision 3). Before merge, the real solve path (generator plus the two-call check) on a system with no solution, a system with a free variable and a system with one answer, all submitted as **own problems**; and, because the whole voice path hangs on it, the real page reader's `SHOW_ME` decision on spoken requests. Script: `server/eval/run-show-me-eval.ts`. Metrics rows (labels, counts, tokens, cost, no text): `server/eval/results/show-me-2026-11-28.jsonl`.

## How it ran

- It drives the production handlers: `handleTeach` with `action: "solve"` and `handleConsult` with `show_me_ok: true`, with the real AI SDK models. The prompts, the schema, the blind solver, the comparer and the acceptance rule are the ones the server runs.
- Models: the solution is written on `gpt-6.1-sol` (the advanced level, provider default effort, none set) and checked by the blind solver and the comparer, also `gpt-6.1-sol`. The page reader ran on `gpt-6-luna` (the tier `la-07` gets).
- **43 provider calls**, counted at the provider by a wrapper with a hard stop (cap 120). Estimated spend from the API's usage and `lib/pricing.ts`: **US$0.079** (solve US$0.073, routing US$0.006; budget guard US$1.50).
- `OPENAI_API_KEY` loaded exec-only with `tsx --env-file=` from the sibling project's env file (`tutoring/.env.local`, the one `docs/plan.md` names); never read or printed. `vercel env pull` was tried first and cannot give the key (it is a Sensitive variable in Vercel; the pulled file held a placeholder and was deleted unread). `TEACH_SEAL_KEY` was generated in the process. No database (in-memory student store).
- **No sound.** Nothing was recorded or played; the live voice was never opened.

## Solve on the three hard cases (3 repeats each)

Statements are the bank's own (`linear-algebra`: la-04, la-05, la-02), typed as own problems, so the tutor had no answer key. The bank's final answers are the ground truth.

| case | bank id | accepted | what the checker said (3 runs) | generated final answer vs the bank | steps | cost per solve | time |
|---|---|---|---|---|---|---|---|
| inconsistent system (no solution) | la-04 | 3 of 3 | agree, agree, agree | "No solution" = "No solution (inconsistent)" | 6, 5, 5 | US$0.0092 to 0.0112 | 19 to 23 s |
| free-variable system (infinitely many) | la-05 | 3 of 3 | **not_single, not_single**, agree | (x, y, z) = (1 - t, 3 - t, t), t any real number = the bank's | 4, 5, 5 | US$0.0057 to 0.0065 | 14 to 16 s |
| one answer | la-02 | 3 of 3 | agree, agree, agree | (x, y, z) = (1, 2, 3) = the bank's | 8, 8, 7 | US$0.0077 to 0.0086 | 17 to 18 s |

9 of 9 accepted, 0 not_checked, 0 provider failures. I recomputed the steps of la-04 (row 3 becomes [0 0 0 2], so 0 = 1), la-05 (y = 3 - z, x = 1 - z) and la-02 (z = 3, y = 2, x = 1) by hand; every line follows from the one before.

**The finding that justifies decision 6.** On la-05 the comparer said `single_answer: false` in 2 of 3 runs (a free variable has infinitely many answers). Practice's rule ("agree only") would have rejected a correct, matching solution twice in three. Solve's rule (`equivalent` and no wrong step, whatever `single_answer` says) accepted all three, and the flags are kept in the log: `checker`, `checker_equivalent`, `checker_single_answer`, `checker_wrong_step` (labels only). Several answers together with a wrong step is still rejected (unit test, `server/test/teach.test.ts`, "several answers combined with a wrong step"). What this does not show: that the checker catches a wrong solution for a hard problem; it never saw one here (a mocked disagreement only proves the branch). That stays a lead for a larger sample.

## Routing: does the page reader answer `SHOW_ME` only when it should (2 repeats each)

One real page picture (the `la-07` fixture), the real consult policy plus the `SHOW_ME` rule.

| what the student says | `show_me_ok` sent | expected | got (2 runs) |
|---|---|---|---|
| "I have no idea where to start." | yes | show_me | show_me, show_me |
| "Can you show me how to do this one?" | yes | show_me | show_me, show_me |
| "I give up, just show me the solution please." | yes | show_me | show_me, show_me |
| "Yes please." after the tutor's "Nothing new since I last looked. Want me to show you how?" | yes | show_me | show_me, show_me |
| "Is my last line right?" | yes | words | words, words |
| "What should I do next?" | yes | words | words, words |
| "Why did the sign change on that line?" | yes | words | words, words |
| "I have no idea where to start." | **no** (an older app) | words | words, words |

16 of 16 as expected. Every SHOW_ME answer came back in 2.6 to 3.5 s; the word answers took 5 to 15 s. The older app never saw an empty answer. Sixteen is a smoke test, not a rate; the live voice has not yet decided to delegate in a real session (decision 3 keeps voice acceptance pending until one records).

## What it cost, in one line

A typed problem's Show me how is about one US cent and 15 to 23 s; a bank or practice problem is free and instant (no model call).

## Repeat

```sh
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-show-me-eval.ts \
  --out server/eval/results/show-me-my-run.jsonl --details /path/outside/the/repo/details.json --reps 3 --max-calls 120 --budget 1.5
```
