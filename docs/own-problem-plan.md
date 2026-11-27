# Plan: check your own homework, and dismiss a wrong circle for good

Revision 2, 2026-11-28, after plan review 1 (REDO, `docs/own-problem-plan.review.md`). Branch `own-problem` off `main` (fd5d816).

Owner goal (Edward, 2026-11-28): make the app good first. Good means (A) check my own homework as I write, (B) teach a concept I have never seen. This plan is A only; B is the next plan.

## Evidence (committed)

`docs/evals/2026-11-28-real-ipad-sessions.md`: 23 hand opens, all bank problem `u3-01`; 50 looks; one false alarm that the voice repeated twice and withdrew after about 53 s. Production is `164329b` (`/api/health` "version" field, 2026-11-28), which `git branch --contains` puts on `main`, 31 commits behind `fd5d816`. The iPad is connected (`devicectl`, 2026-11-28). Clear marks does log `marks_cleared` with a count, but records no dispute.

## What changes from revision 1

Removed: bare `own` (every entry point has a course), blank-statement starts (a handwritten question can slide out of the page picture, `PageSnapshot.swift:180`), `read_line`, `problem_text` on heartbeat (no model call there), the "first 30 pages" mitigation. Tier is no longer assumed: step 0 measures it. Live voice is handled on its own path (it does not use `referenceBlock` and its model ignores level, `policy.ts:194`, `config.ts:101`). Dismissal is keyed to the ink, not to a history entry, and it clears the voice's queued hint.

## Step 0: measure before choosing the model (R38)

Add `--no-reference` to `server/eval/run-eval.ts`: each fixture is judged as an own problem (typed statement = the fixture's `prompt_plain`, no worked solution, no final answer), through the real `handleWatch`. Run it on the existing 84 course fixtures (42 with a planted mistake, 42 correct, clean set) for gpt-6-luna and gpt-6.1-sol, plus the 13 real correct page pictures of session `2026-11-14T11-00-54` (false alarms only; typed statement "7x - 4 = 3x + 16"). About 200 looks, under US$1 by `pricing.ts`.
Pick the tier for own problems by: fewer false alarms first, then more caught on the right line; a tie goes to luna (cheaper). Write the result to `docs/evals/2026-11-28-no-reference-eval.md`. The tier becomes one constant (`OWN_PROBLEM_LEVEL`) set from this result.

## Step 1: server

- `resolveProblem(problem_id, problem_text?)` in `server/lib/problems.ts` replaces `findProblem` in watch, ask, consult and live-session; heartbeat keeps `findProblem` but also accepts `own:<slug>` as valid for metering.
  - A bank id resolves as today.
  - `own:<slug>`: the slug must be a course in the manifest (else 422 `unknown_course`); `problem_text` is required, trimmed, 1 to 500 characters (else 422 `invalid_request`). Resolves to `{ id, prompt_plain: problem_text, worked_solution: [], final_answer: "", course: slug, level: OWN_PROBLEM_LEVEL, own: true }`.
- `referenceBlock` no-reference branch (watch, ask, consult): "The student typed this problem. There is no reference solution. Before judging a line, solve the problem yourself and recompute every number on the line you would flag. If a digit or sign is hard to read, wait." `buildLiveInstructions` already carries `prompt_plain`; it gains one sentence for own problems ("there is no answer key; when unsure, ask the page reader").
- Empty-answer guards: `server/lib/decision.ts:39` and `server/lib/record/reword.ts:72` skip the leak check when `final_answer` is empty.
- Logs: `problem_kind: bank | own`, `problem_text_chars` (count only), `course`, `tier`.

## Step 2: iPad

- First row of every course's problem list: "My own problem". It opens a sheet with one text field ("Type the problem", 1 to 500 characters), Start disabled while empty, and Cancel. Start opens `ProblemScreen` with `Problem(id: "own:<slug>", promptPlain: text)`; the card shows the typed text like a bank prompt.
- `TutorClient` sends `problem_text` with watch, ask, consult and live-session for own problems only. `--scripted-client` mirrors the server: own problems always wait.
- Log `own_problem_started` with `course` and `chars`.

## Step 3: "Not a mistake" (iPad)

- The hint callout gets a "Not a mistake" button (44 pt). The overlay disables hit testing today (`MarksOverlay.swift:31`); only the button's frame becomes hit-testable, so ink around the callout still reaches the canvas.
- Tap: the mark is removed; its `inkSignature` (already stored on every `Mark`, `TutorSession.swift:1099`) is added to the page's `disputed` set; log `mark_disputed` (request id, line, model; no text).
- Later interrupts: before a mark is drawn, if the flagged line's current ink signature is in `disputed`, the interrupt is dropped locally (log `interrupt_suppressed_disputed`), whatever the line number now is and however many looks have passed. Rewriting the line changes its signature, so a new mistake there is still caught.
- The history sent to the server also gets `{action: "disputed", line}` (advisory only; the local check is what guarantees it).
- Voice: the tap clears a held hint in `LiveVoice` (`held = nil`, cancel `heldReleaseTask`, log `live_hint_dropped reason: disputed`) and pushes context: "The student marked line N as not a mistake; the check was wrong. Do not repeat that hint. If asked about it, ask the page reader to look again." The base voice stops speaking if it is speaking that hint.

## Not in this plan

Teach mode (next plan), photographing or handwriting the problem statement, saving pages between opens, the line-grouping fix for arrows and underlines (a lead until real strokes confirm it), the Apple Developer account (Edward: after the app is good), merging `free-launch` or `iap-subscription` (Edward's money model).

## Tests

- Server, `tsx --test` (node:test), only the files touched: resolver (bank id, `own:<slug>`, unknown slug, missing or over-long text, heartbeat accepts own), the no-reference prompt text, an interrupt with empty `final_answer` survives `finalizeDecision`, the `disputed` history entry renders, live-session wiring through the existing fake gateway (scripted live answers 503 by design, `live.ts:124`).
- iPad unit tests: own `Problem` round trip; requests carry `problem_text` only for own problems; dispute removes the mark, suppresses a later interrupt on the same ink after 12 more looks and after a line is inserted above it, and does not suppress after the line is rewritten; held live hint cleared.
- CI (`ios.yml`, Blacksmith, manual run once when the branch is ready): build, unit tests, a UI test that the row and sheet exist and Start opens the page.
- Real iPad (QA receipts, screenshots plus the session log): type a problem, write it with one planted slip, see the circle; tap Not a mistake; keep writing past 10 looks; write a line above; confirm no repeat by circle or voice; rewrite the disputed line with a real mistake and confirm it is caught.

## Build and deploy

- iPad builds: CI only builds an unsigned simulator app (`ios.yml:65`). The device build is signed with Edward's free "Apple Development" identity, which lives in this Mac's keychain, so it is one incremental `xcodebuild` Debug build per QA round on the Mac, installed with `devicectl`. Everything else (full test runs) stays on CI.
- Server: `server/scripts/codes migrate` (migration 004 is additive), then `vercel deploy --prod` from `server/` after merge; `/api/health` must show the merged commit.

## Risks

- Own-problem accuracy is unknown until step 0; if both tiers raise false alarms on more than 2 of the 13 real correct pages, stop and report instead of shipping the row.
- A typed statement can hold an instruction. It is student content under the existing rule, capped at 500 characters.
