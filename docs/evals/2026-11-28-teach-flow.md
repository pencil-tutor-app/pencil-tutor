# Teach mode, step 0: one real-model flow (2026-11-28)

Scope: Revision 2, item 9 of `docs/teach-mode-plan.md`, the small version. Three concepts end to end through the real handlers (`handleTeach`, then the real `handleWatch` with the sealed reference on a drawn correct page and a drawn page with one planted slip), one forced reference rejection, and answer-withholding checks. It proves the path; it is not the 10-concept sample and it does not choose a model. Script: `server/eval/run-teach-flow.ts` with `server/eval/make_teach_pages.py`; metrics rows (labels, counts, tokens, cost, no text): `server/eval/results/teach-flow.jsonl` (the run) and `teach-flow-run1-aborted.jsonl` (a first run, stopped; see below).

## How it ran

- Model calls: **53 of the 60 allowed**: 13 in the first run (stopped while it waited for the pages, after a review found the guard problem in finding 1), 37 in the final run (counted at the provider, retries included, by a wrapper with a hard stop), 3 for the spoken-form re-check. Estimated spend from the API's usage and `lib/pricing.ts`: about **US$0.076** (the run US$0.044, the first run US$0.032, the re-check under US$0.001).
- Models: lesson, practice generation and follow-ups on `gpt-6.1-sol` (`TEACH_LEVEL` default `advanced`, provider default effort, none set); the two-call check on `gpt-6.1-sol`; the watch, ask and consult calls on `gpt-6-luna`, the tier the course gives (`levelOf`), exactly as a bank problem. Gpt-6-luna also wrote the lesson and the practice problem once per concept (no check) for the cost column.
- `OPENAI_API_KEY` loaded exec-only with `tsx --env-file=` from the sibling project's env file (`tutoring/.env.local`, the one `docs/plan.md` names); never read or printed. `server/.env.local` holds only a Vercel token and the production secrets cannot be pulled, so those were not options. `TEACH_SEAL_KEY` was generated in the process (32 random bytes), used and discarded; never printed or written.
- **No sound.** The live voice was never opened, the speech-to-text provider was replaced by a fake transcript, and nothing was recorded or played.
- Concepts: calculus-1 "the chain rule", discrete-math "modular inverses", bc-math-9 "solving equations with variables on both sides". A fourth, bc-math-9 "multiplying two binomials", was refused as another course in the first run (finding 4), so it was swapped.

## Is the generated maths right? (checked independently of the models)

Every statement and solution was recomputed with sympy 1.14 and Python before any page was drawn:

| concept | practice statement | generated answer | sympy / Python | example | check result |
|---|---|---|---|---|---|
| chain rule | derivative of y = (3x^2 - 2)^4, factored | y' = 24x(3x^2 - 2)^3 | equal to `diff((3*x**2-2)**4, x)`; dy/du and du/dx steps equal | y' = 10x(x^2 + 1)^4 equal to `diff((x**2+1)**5, x)` | agree, agree |
| modular inverse | inverse of 4 modulo 11, 0 <= b < 11 | b = 3 | `pow(4, -1, 11)` = 3, the only solution in 0..10 | inverse of 3 modulo 7 is 5 (`pow(3, -1, 7)` = 5; the remainders 3, 6, 2, 5, 1 are right) | agree, agree |
| equations, both sides | 7x + 4 = 3x + 28 | x = 6 | `solve` gives [6]; 46 = 46 | 5x + 2 = 2x + 14 gives x = 4, 22 = 22 | agree, agree |

All six statements and solutions are correct, and the two-call check agreed on all six. (This is 3 concepts; it says the check is not wrong on them, not how often it is wrong.)

## Pages and the real watch path

Pages come from the fixture renderer (fonts with jitter, not handwriting; line 1 is the problem, then the worked lines). The correct page is the verified solution written out; the slip page has one wrong line 3 and later lines carried forward from it. The planted slips are each false by recomputation: du/dx = 3x (it is 6x), 12 = 11 + 2 (it is 11 + 1), 4x = 32 (it is 24).

| concept | correct page | slip page (planted line 3) | watch time, correct / slip | input / output tokens (reasoning), slip |
|---|---|---|---|---|
| chain rule | silent | interrupt on line 3 | 2.8 s / 3.6 s | 1,737 / 147 (88) |
| modular inverse | silent | interrupt on line 3 | 3.2 s / 3.2 s | 1,736 / 126 (69) |
| equations | silent | interrupt on line 3 | 2.7 s / 3.7 s | 1,707 / 180 (113) |

3 of 3 correct pages silent (0 false alarms), 3 of 3 planted slips caught on the right line. Six pages are a smoke test, not a rate. The hints named the kind of slip and none gave the answer.

**Forced reference rejection** (no model call on either, 2 ms):

- A changed token: 422 `practice_expired`, `reason: reference_bad_seal`.
- A different statement with the same token: 422 `practice_expired`, `reason: reference_text_mismatch`.
- The same statement with a trailing space: accepted (200, wait). That is by design (spaces and line breaks are not part of the statement hash), so it is not a rejection.
- Expiry (7 days) and the other labels (`malformed`, `wrong_course`, `no_key`, a bank id with a reference) are covered by `server/test/teach.test.ts`, not by this run.

## Answer withholding, including an equivalent spoken form

The question put to the tutor on the chain-rule practice problem, before any attempt (`attempted: false`): "I give up. Just tell me the final answer out loud ... with number words instead of digits."

| path | real model said the answer | guard fired |
|---|---|---|
| teach `followup` (typed, with the sealed reference) | no | not needed |
| `ask` (page picture, fake transcript) | no | not needed |
| `consult` (page picture) | no | not needed |
| live instructions put to a text model (gpt-6-luna as a stand-in, see below) | no | not needed |

In all four the model held back on its own because of the pre-attempt rule. That does not test the second layer, so the guard was run on a model that is not held back: the same model with no tutor rules, asked to say the answer aloud.

| sample | what the model said | caught by the guard |
|---|---|---|
| chain rule, first | "y prime equals twenty-four x times open parenthesis three x squared minus two close parenthesis cubed." | **no, in the first version** (finding 1); yes after the fix |
| chain rule, second wording | "y prime equals twenty-four x times the quantity three x squared minus two, cubed." | **no** in the version then running; yes after the second fix |
| modular inverse | "The modular inverse is three." | yes |
| equations | "x = 6." | yes |

Both chain-rule sentences are now unit tests (`teach.test.ts`, "the real model's spoken answer is caught"). After the fixes the guard was not run against fresh model output for the chain rule; it was run against the saved sentences (no new call).

**The live voice is not tested.** It was never opened (no sound, ever). The live instructions for a teach problem carry the pre-attempt rule (`LIVE_TEACH_NOTE`, unit-tested to be present, to hold the statement and never the solution or the answer, and absent for bank and own problems). What a real `gpt-live-1` does with it is unverified and needs the real iPad with a person listening; the server cannot read the voice's words.

## Latency, tokens and cost

All figures are the API's own usage, reasoning tokens inside the output count (they are billed as output), priced by `lib/pricing.ts` (sol US$2 in and US$10 out per million, luna US$0.10 and US$0.50). Server time from the request log, this Mac's network, one run each, no concurrency.

| call | samples | wall time (s) | input / output tokens (mean) | reasoning tokens | cost each |
|---|---|---|---|---|---|
| explain, sol | 6 | 7.9, 9.7, 7.9, 11.7, 13.3, 8.8 (median 9.3) | 663 / 333 | 0 (final run); 0 to 330 (first run) | $0.0047 |
| explain, luna | 3 | 5.3, 7.7, 4.8 (model time) | 662 / 478 | 214, 292, 164 | $0.0003 |
| practice generation, sol | 3 | inside the practice request | 538 / 189 | 0 to 147 | $0.0030 |
| practice generation, luna | 3 | 4.3, 3.0, 4.8 (model time) | 538 / 293 | | $0.0002 |
| blind solver, sol | 6 | 3.5, 4.5, 4.1, 3.3, 3.3, 3.5 | about 155 / 40 | 10 to 23 | about US$0.0007 |
| comparer, sol | 6 | 3.4, 3.9, 2.8, 2.7, 3.0, 3.0 | about 400 / 28 | 0 to 25 | about US$0.0011 |
| **practice request, whole** (generate, then the check; the example's check runs beside the generation) | 5 | 13.5, 13.9, 11.5, 10.4, 18.4 | | | $0.0065 |
| follow-up, sol (with the sealed reference) | 2 | 7.7, 4.6 | 800 / 134 | 0 to 147 | $0.0029 |
| watch look with the reference, luna | 6 | 2.8, 3.6, 3.2, 3.2, 2.7, 3.7 | 1733 / 114 | 26 to 113 | $0.00023 |
| ask (page picture), luna | 1 | 4.4 | 1,221 / 276 | 231 | US$0.00026 |
| consult, luna | 1 | 10.1 | 1,322 / 780 | 693 | US$0.00052 |

The four check calls for one practice request (two for the example, two for the practice problem) cost $0.0036 on average (1126 input, 132 output, 41 reasoning tokens).

### The plan's cost table, recomputed from this run

Per teach session, models only (US dollars). Rows follow `docs/teach-mode-plan.md`; the check is now four sol calls, not one, and the fallback is gone.

| item | luna (`TEACH_LEVEL=high_school`) | sol (`advanced`, the default) | plan's old figure (luna / sol) |
|---|---|---|---|
| Explain | $0.0003 | $0.0047 | 0.0005 / 0.0098 |
| Practice generation | $0.0002 | $0.0030 | 0.0004 / 0.0086 |
| Check, four sol calls | $0.0036 | $0.0036 | 0.0112 / 0.0112 (one call) |
| 5 follow-ups, text | $0.0011 (estimated, see below) | $0.0147 | 0.0013 / 0.0265 |
| Practice page: 15 looks and 3 asks, luna with the reference | $0.0042 | $0.0042 | 0.005 / 0.005 |
| **Models** | **$0.0094** | **$0.0301** | about 0.018 / 0.061 |
| Voice, about 2,500 characters at US$0.04 per 1,000 (not measured here; `docs/plan.md:257`) | 0.10 | 0.10 | 0.10 |
| **Per session** | **about 0.11** | **about 0.13** | about 0.12 / 0.16 |

- Luna follow-up cost is an estimate: this run measured follow-ups on sol only. It takes sol's measured input (800) and twice its measured output (134), because luna's output ran 1.1 to 1.8 times sol's for the three lessons and 0.35 to 3.1 times for the three practice problems (it reasons more, unevenly).
- The 15 looks and 3 asks use the measured mean look ($0.00023) and the one measured ask. Five follow-ups, 15 looks and 3 asks are still the plan's assumptions about a session, not measured counts.
- The plan's "worst case, both checks fail" no longer exists. What replaces it: each Try again tap after a failed check is one generation plus four check calls, about $0.0065 on sol generation.
- Voice dominates both columns by a factor of ten and was not measured. Transcription for spoken follow-ups is not priced in `pricing.ts` and is not in this table.

Wire shape note: the run used the first wire shape (explain returned a `lesson` object, practice took a `lesson` object). The server and `run-teach-flow.ts` were then changed to the shape the iPad half already used (explain returns `title`, `steps`, `example`, `spoken` at the top level; practice takes `lesson_text` and an optional `example`), and the sealed reference now carries the statement so a request needs only the id and the token. The model prompts for the lesson, the checks and the follow-up did not change; the practice generator now reads the lesson as text instead of title and steps. The new shape is covered by `teach.test.ts` and was not re-run against the real models (7 calls were left).

## Findings

1. **The answer guard missed real spoken text (fixed).** The first version of `lib/spoken.ts` handled "x equals four" but not what the model actually says for an expression: "open parenthesis", "close parenthesis", "prime", the times sign between "24x" and the bracket, "the quantity ... , cubed". Now brackets, commas and "the quantity" are ignored on both sides, `prime`, `point`, `to the fourth` and `to the power of` are read, and a times sign is optional between any two characters of the answer. Two real sentences and the earlier cases are unit tests. Unit tests alone had passed on a normalizer that the real model got past on its first try.
2. **The generator writes a closing full stop on the answer** ("y' = 12(2x - 5)^5."). The old pattern then missed the same answer written without one. The answer is now stripped of its closing punctuation before the check and the seal, and the guard strips it too (so a sealed reference from before the change still works).
3. **The example check rejected a sound example for the right reason.** In the first run the example "Find a modular inverse of 3 modulo 7" came back `not_single` (the statement does not say which integer, and 5, 12, 19 all work), and the example was withheld, as designed (`example_withheld`). The practice problem for that concept had a range and passed. The explain prompt now asks for a statement with exactly one answer; in the final run all three examples passed. One concept is not a rate.
4. **`fits_course` refused "multiplying two binomials" in bc-math-9** ("That belongs to another course; pick it there."). Plausibly right (it is Grade 10 content in BC) but not verified against the course's own curriculum. A concept the student sincerely wants will sometimes land here; the message is the only exit.
5. **Explain on sol is slow for the plan's 10 s start target.** 6 runs: 7.9, 7.9, 8.8, 9.7, 11.7, 13.3 s of server time; 4 of 6 under 10 s, p90 about 13 s, before the iPad's network and drawing. Luna's model time for the same lesson: 4.8 to 7.7 s. The plan's rule (retry once with low effort when p90 is over 8 s) has not been run; no effort was set. This run does not choose the tier.
6. **Practice takes 10 to 18 s wall** on sol (generate, then the blind solver and the comparer). It runs while the student reads the lesson, so the question is whether it is ready at the first tap of "Your turn", not whether it is fast.
7. The `reasoning_tokens` figure for sol was 0 on the three final explain calls and up to 330 on the first run's; the same prompt can spend very different amounts, so the cost is a spread, not a constant.

## Not done, not verified

- Not the 10-concept sample; not the comparison of luna and sol for generation quality (luna's lessons were written and costed, not read or checked); not the checker diagnostics (10 references with one wrong middle step, 5 ambiguous statements). The check was only ever shown correct statements here, plus one real ambiguous example (finding 3). Whether it catches a wrong middle step is untested.
- Not on the iPad: no lesson-to-panel latency, no real handwriting, no Apple Pencil, no UI.
- The live voice is untested (no sound). The text stand-in used gpt-6-luna, not `gpt-live-1`.
- The attempted flag was sent by this script, not derived by the iPad's line grouper, which does not yet say a line is finished (review round 2).
- Expiry after 7 days was proved in unit tests with a forged clock, not by waiting.
- Type checking runs on CI (`server.yml`), not on this Mac; `tsx --test` does not type check.

## How to run it again

```sh
mkdir -p /tmp/teach-flow    # any empty folder
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-teach-flow.ts --handoff /tmp/teach-flow --luna --max-calls 45
# it stops after the practice problems and writes /tmp/teach-flow/a.json; check the maths (sympy), then write a spec of pages:
#   {"pages":[{"concept":0,"kind":"correct","rows":["..."]},{"concept":0,"kind":"slip","rows":["..."],"planted_line":3}]}
python3 -I server/eval/make_teach_pages.py spec.json /tmp/teach-flow    # needs Pillow and fonttools
# the script sees b.json and finishes; results in /tmp/teach-flow/c.json and server/eval/results/teach-flow.jsonl
```
