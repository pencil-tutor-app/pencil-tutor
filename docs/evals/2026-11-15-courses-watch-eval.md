# Does the tutor catch mistakes on the new courses? Watch eval, 2026-11-15

Plain words first, the official term once at the end of a section where there is one.

**Short answer.** On clean synthetic pages the standard-tier tutor (`gpt-6-luna`, the production default) circled the exact planted
line on 42 of 42 mistake pages and stayed quiet on 42 of 42 correct pages, across all 14 new courses. On a deliberately messier copy
of the same pages it still caught 40 of 42, with 1 wrong-line and 1 silent page, and raised 2 false alarms on 42 correct pages (one
of those is a defect in my picture, not in the tutor). No course shows a problem that a bigger model would obviously fix. Cost is
about $0.00025 per look. The numbers are good, but they come from fake handwriting and only 3 problems per course; read the limits
section before trusting them for a child's real page.

## What was run

- Code: main `77db5e3` (production) plus this branch's eval changes. Drives the real `handleWatch` (`server/lib/watch.ts:30`) with the
  real prompt (`server/lib/policy.ts`), picture handling, schema and line check, exactly as the earlier 30-page eval did
  (`server/eval/run-eval.ts`, extended with `--fixtures` and `--max-calls`).
- Model: `openai:gpt-6-luna`, no reasoning-effort override. The production Vercel project sets no `WATCH_MODEL`, `WATCH_PROVIDER` or
  `WATCH_EFFORT` (checked by variable name only), so this is what students get. Every course is `tier: standard`
  (`shared/courses/index.json`).
- No database: the harness uses an in-memory student store (`server/eval/run-eval.ts`, `MemoryStudentStore`), so the usage meter and
  Neon were never touched.
- Keys: `vercel env run -e production` skipped 6 secret values ("cannot be pulled from the production Environment") and the harness then
  found no `OPENAI_API_KEY`, so the key was loaded exec-only with `tsx --env-file=<local env file>` the way the harness documents. Never
  printed or saved.
- Pages: 14 courses x 3 problems x 2 pages = 84 pages. The brief said 15 courses and 90 pages, but the manifest has 15 entries only
  when the old `bc-math-9-unit-3` set is counted; without it there are 14. Pages are therefore 84, not 90.
  Problems and planted mistakes are in `server/eval/make_course_fixtures.py` (the `prob(...)` lines), the answer key for every page
  is `server/eval/fixtures/courses/manifest.json`.
- Two renderings of the same 84 pages: **clean** (dark pen, as the 30-page set) and **messy** (`--messy`: twice the glyph tilt and
  bobbing, rows that drift, grey pencil, paper grain, extra blur, 0.78 downscale).
- Looks used: **176 of the 200 allowed** (84 clean + 84 messy + 8 repeats of the four messy failures). 0 errors, 0 schema failures, 0
  server downgrades. Estimated cost $0.042 in total (price table `server/lib/pricing.ts`; an estimate, not a bill).
  The SDK allows one retry on transport errors; none showed as an error row, but retries are not separately visible.

### How the pages were made

Handwriting-style fonts, all SIL Open Font License from Google Fonts: Patrick Hand, Kalam, Caveat, Indie Flower. Noto Sans Math (also
OFL) fills the few glyphs those lack (arrows, set and logic symbols). Per-glyph size, rotation, baseline and spacing jitter, per-page
slant, the faint grey margin line numbers that `PageSnapshot.swift` draws, 1024 px wide, 544 to 743 px tall (the app's limit is 1024 px
on the longest side). Fractions are stacked, exponents raised, square roots get an overbar, matrices get brackets. The two pages of a
problem use different pens. Each mistake is one realistic slip with every later line carried forward from it. Mistake types: sign
error (7), arithmetic slip (6), wrong operation (2), misapplied rule (2), moved a term with the wrong sign (2), and 23 one-offs
(dropped carry, order of operations, forgot to distribute, chain rule omission, lost roots by dividing by sin x, and so on).

## Results

Measured per page: **caught** = interrupted on exactly the planted line; **wrong line** = interrupted on another line; **silent** =
waited on a mistake page; **false alarm** = interrupted on a correct page.

| | mistake pages | caught | wrong line | silent | correct pages | false alarms |
|---|---|---|---|---|---|---|
| Clean set | 42 | **42 (100%)** | 0 | 0 | 42 | **0 (0%)** |
| Messy set | 42 | 40 (95%) | 1 (2%) | 1 (2%) | 42 | 2 (5%) |
| Both | 84 | 82 (98%) | 1 | 1 | 84 | 2 (2%) |

With 42 pages a 0 does not mean zero: the true clean false-alarm rate could still be around 7% at 95% confidence (rule of three).

### Per course

Three mistake pages and three correct pages per course per set.

| course | clean: caught / false alarms | messy: caught / wrong line / silent | messy: false alarms | recommendation |
|---|---|---|---|---|
| bc-math-5 | 3/3, 0 | 2/3, 0, 1 | 0 | standard; watch (see below), test on a real child's page |
| bc-math-6 | 3/3, 0 | 2/3, 1, 0 | 0 | standard; watch (operator misread) |
| bc-math-7 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-math-8 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-math-9 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-fmpc-10 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-fm-11 | 3/3, 0 | 3/3, 0, 0 | 1 | fine on standard (the one false alarm did not repeat) |
| bc-pc-11 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-calc-12 | 3/3, 0 | 3/3, 0, 0 | 1 | fine on standard (that false alarm is my picture's fault) |
| bc-fm-12 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| bc-pc-12 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| calculus-1 | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| discrete-math | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard |
| linear-algebra | 3/3, 0 | 3/3, 0, 0 | 0 | fine on standard (matrices included) |

No course is recommended for the advanced tier, and none needs prompt work on this evidence. I did not run the advanced model, so I
cannot say it would do better on the two messy failures; both look like picture-reading problems rather than reasoning problems.
Three problems per course is a sample, not a rate: "3/3" means "no problem found", not "proven".

### Which mistake types were missed

Clean set: none. Messy set: one arithmetic slip (a student's `36 x 4 = 124`, with the correct 144 in the reference) and one misapplied
formula (`(6 x 10) x 5 / 2` for a trapezoid). Everything else was caught on both sets: all 7 sign errors, both wrong-operation
pages, both wrong-sign term moves, the other misapplied rules, and the subtle ones (dividing by sin x and losing two roots, the quotient rule
in the wrong order, negative reciprocal losing its sign, an induction step that misuses an exponent law).

### Failures, with what the tutor said (problem id, planted mistake)

1. `m5-26` messy, silent. Planted `36 x 4 = 124` (line 4). First look said "All steps are correct." Repeats: one waited again
   ("The student's steps are correct"), one caught it ("Check the multiplication fact for thirty-six times four"). So about 1 in 3.
   Cause not verified. The picture shows 124 plainly, so a likely cause is the reference solution (144) priming the reader to see
   what it expects. That is a hypothesis.
2. `m6-55` messy, wrong line. Planted `(6 x 10)` instead of `(6 + 10)` on line 2. The tutor circled line 3 in all 3 looks: "The sum of the
   parallel sides is calculated incorrectly", hint "Check the addition inside the brackets before you multiply". It read the small
   multiplication sign as a plus, so it blamed the next line. Stable, and a real misread. The child would still be pointed at the
   right bracket, but the circle is one line low.
3. `ca12-22` messy, false alarm on a correct page. The page is a limit-definition derivative ending `f'(x) = 2x - 3`. In the messy
   picture the prime mark disappeared (blur plus downscale), so the last line reads `f(x) = 2x - 3`. The tutor said "Check that you're
   naming the derivative, not the original function", 3 of 3 looks. That is the tutor reading my picture correctly. It is a fixture defect
   (the clean picture shows the prime). Counting it out, messy false alarms are 1 of 42.
4. `fm11-11` messy, false alarm. "Check the constant term in the expression for the second angle when you substitute for x." Did not repeat
   in 2 more looks, so it is noise, cause unknown.

Every failure is on the messy set. Digit and operator legibility is where the margin is thin, not the maths.

### Do the hints give the answer away?

85 hints were written (42 clean, 43 messy, counting false alarms). None contained the problem's final answer, and none contained a
corrected number from the planted line (automatic check in `server/eval/report_courses.py`, which compares each hint with the correct
version of the page; the server's own `hint_reveals_answer` downgrade also fired 0 times). I also read all of them. They point at the kind
of slip ("Check the sign when you move the 8 to the other side"), which is what `WATCH_POLICY` asks for. A few go close to naming the fix, and
a stricter policy might trim them: `m6-27` "How many times does eight fit into forty?" (that is the corrected division), `pc11-67`
"Divide every term by two", `m9-08` "Apply the power to each factor", `m9-26` "Multiply 0.5 by both terms", `pc11-26` "there should be a middle term
and a constant term". They state a rule, not a value, so I count them as inside the policy and not leaks. Every written hint was 8 words
or fewer (checked). The check is on text only; I did not judge whether a real child would find them too hinty.

### Cost and time

- Per look: about $0.00025 (input 1,808 tokens, output 136 of which 84 reasoning, clean set; $0.00023 on the messy set, which is smaller
  after the downscale). Estimated from `pricing.ts` at $0.10 per million input and $0.50 per million output tokens.
- Latency p50 3.1 s, p90 4.1 s, max 10.0 s (messy set).
- For scale: the earlier 30-page eval measured `gpt-6.1-sol` at $0.00243 per look against $0.00016 for luna, about 10 times. The advanced
  tier would be a real cost step, and nothing here argues for it.

## Limits, said plainly

- Fake handwriting. A font cannot reproduce a child's crossings-out, uneven fractions, run-together digits or hand-drawn matrix
  brackets. Real pages will be harder than these, so the clean numbers are an upper bound. The messy set only nudges toward that; the
  real test is Edward's iPad pages (see "Pulling Edward's real handwriting" in `docs/how-to-run.md`).
- The tutor is shown the reference worked solution. A planted mistake that departs from that route is easy to see. This eval does
  **not** test the harder cases: a correct page that uses a valid different method (the false-alarm risk), a half-written last line, a
  mistake in a line the reference does not have, or a student who fixes a mistake mid-page. The 30-page BC Math 9 set covers the
  half-written case; nothing covers the alternative-method case for these courses.
- Each mistake sits on one line and the lines after it follow from it, so "first wrong line" is unambiguous. Real mistakes are murkier.
- One sample per look (plus 8 repeats). The model is not deterministic: `m5-26` flipped between looks.
- 3 problems per course, picked by me to spread topics and difficulty, not drawn at random. Per-course results are anecdotes.
- Hint quality was checked for leaks and policy shape, not for whether it teaches well.
- Noto Sans Math glyphs (arrows, logic symbols) look typeset, not handwritten.

## Suggested next steps

1. Run the app on the iPad with real Grade 5 and 6 work first: those are the courses where the messy set cost a catch.
2. If real pages show lost prime marks or small operators misread, try the advanced tier on that course only, and measure again before
   switching (`"tier": "advanced"` in `course.json`; I did not touch it).
3. Add alternative-method and half-written pages for the 14 courses; that is the missing half of this test.

## Files

- Fixtures and answer keys: `server/eval/fixtures/courses/` (clean), `server/eval/fixtures/courses-messy/` (messy), each with `manifest.json`.
- Builders: `server/eval/make_course_fixtures.py` (add `--messy`), report: `server/eval/report_courses.py`.
- Raw looks: `server/eval/results/courses-2026-11-15.jsonl`, `courses-messy-2026-11-15.jsonl`, `courses-messy-repeat-2026-11-15.jsonl`
  (ids, tokens, cost and the tutor's own words about synthetic pages; no real student content).
- Re-run recipe: `docs/how-to-run.md`, section "Model eval and cost per look".
