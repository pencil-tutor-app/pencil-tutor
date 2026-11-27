# Real iPad sessions, 2026-11-13 to 2026-11-16: what the logs show

Read 2026-11-28 from Edward's iPad (iPad 9th generation, device listed "available (paired)" by `xcrun devicectl list devices` that day). The app writes `session-*.jsonl` in its Documents folder (labels, counts and timings; Debug builds also keep the page picture of each look). 29 sessions were hand use; the rest (2026-11-14 18:41 UTC onward, about 70) were the handwriting replay runner and are excluded. The raw files stay off the repo; this is the summary.

## Numbers

| what | value | log source |
|---|---|---|
| Problem opens by hand | 23, all `u3-01` (one bank problem) | `problem_opened.problem_id` |
| Tutor looks | 50: 24 on gpt-6.1-sol, 25 on gpt-6-luna, 1 scripted | `decision.model` |
| Interrupts | 3, all on gpt-6.1-sol: 2 true catches, 1 false alarm | `decision.action`, read against the conversation and the rewrite that followed |
| Look time, end to end | 2.7 s to 8.9 s, middle 3.7 s | `decision.latency_ms` |
| Errors | 0 | `type: error` |

## The false alarm

Session `2026-11-14T01-48-59` (gpt-6.1-sol, a "Check my work" look on revision 39): the tutor circled line 3 and hinted at the addition 16 + 4, which was correct as written. The student said the sum was right twice; the live voice repeated the hint twice and withdrew it about 53 s after the circle appeared (`decision` at 01:50:16 UTC, withdrawal `tutor_said` at 01:51:09). The page reader on the same revision described the row as "equals twenty-seven", so the likely cause is a misread digit, not wrong maths; the picture of that look was not kept (that build saved none), so this stays a lead. The only control on the page was Clear marks, which logs `marks_cleared` with a count and nothing about a dispute (`ios/PencilTutor/Session/TutorSession.swift:407`).

## Line grouping on real ink

`page-2026-11-14T11-00-54.963Z-af306109-watch-w12-r82.png` (old build, before the 2026-11-15 grouping rewrite): 7 written rows, logged as `lines: 6, side_lines: 2`. Arrows and underlines between rows sit in the merged groups. Lead only: the current grouper has never seen real strokes, and strokes are not saved.

## Not a defect

Session `2026-11-14T11-41-13`: non-maths notes on a problem page; the tutor waited on all 10 looks, which is right.

## What it means

Only bank problems can be opened (every model endpoint resolves `problem_id` through `findProblem` and answers 422 `unknown_problem` otherwise), so Edward's own homework cannot be checked. That and the cost of a false alarm are the first two gaps; plan: `docs/own-problem-plan.md`.
