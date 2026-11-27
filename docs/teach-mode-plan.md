# Plan: teach mode (learn a new concept, then try one yourself)

Revision 1, 2026-11-28. Branch `teach-mode`, cut from `main` once `own-problem` has merged. The plan builds on `f670b15` (the own-problem server work) and on the own-problem iPad work that is still uncommitted. Line numbers in `ios/` are from that working tree and will move.

Owner goal (Edward, 2026-11-28): "I'm learning some brand-new concept... this just helps with homework and helps me with brand-new stuff too." This is job B. Job A is `docs/own-problem-plan.md`.

## Revision 2 (2026-11-28, after plan review 1, REDO): this section wins over anything below it

1. **Checking is two calls, and the first one is blind.** Call 1 (solver, advanced ask model, `ASK_EFFORT_ADVANCED` is the effort knob, not `ASK_EFFORT`) gets only the canonical statement and returns its own final answer. Call 2 (comparer, same model) gets the statement, the generator's steps and final answer, and the solver's answer, and returns `{equivalent, single_answer, first_wrong_step}`. The reference is accepted only when both agree, the answer is single, and no step is wrong.
2. **One canonical statement.** The generator returns `prompt_plain` only, in the notation `MathMarkup` already reads; the iPad renders it with the same parser the problem list and card use (`ProblemListView.swift:171`, `ProblemCardView.swift`). No separate `prompt_parts` is generated, so what is shown and what is checked are the same string (the mismatch behind the m5-26 and fm11-39 false alarms cannot happen).
3. **No unchecked fallback, no automatic regeneration.** If the check fails, `practice` answers 200 with `{problem: null, reason: "not_checked"}` and the iPad shows "I couldn't make a practice problem I'm sure of. Try again?" with a Try again button. Each tap is one generate plus two checks. Logged `practice_not_checked`.
4. **A rejected example is withheld, not shown with a warning.** The lesson shows its steps; the example slot says nothing and `example_withheld` is logged. The example is checked by the same two-call path, in parallel with practice generation.
5. **No truncation.** Step and line limits are in the structured-output schema; an answer over the limit is a failed call (`teach_too_long`) and the iPad says "That came out too long, try again." Nothing is cut mid-explanation.
6. **Answers before an attempt are refused by state, not by text matching alone.** The iPad knows whether the practice page has any finished line (the line grouper). Until it has one, ask, consult and followup requests about the practice carry `attempted: false`, and the server tells the model it must not give the final answer or any line that contains it. The text guard stays as a second layer and gets a spoken-form normalizer (number words zero to twenty, "equals", "minus", "plus", "times", "over", "squared") with unit tests on both "x = 4" and "x equals four". An expired or invalid reference is a 422 `practice_expired` (the iPad offers a new practice), never a silent fall back to an own problem, so the guard is never lost. Expiry is 7 days.
7. **Live voice follows the normal rule.** The practice page is a normal `ProblemScreen`, so live starts only for a code whose plan has live (`TutorSession.swift:596`), exactly as on any page. Edward approved live for his own code on 2026-11-28; the US$20 plan's codes have it off. The lesson screen itself never starts live. The "teach never opens live" line below is withdrawn.
8. **Course fit.** `explain` returns `fits_course` besides `is_math`; a concept outside the course gets "That belongs to another course; pick it there" and `concept_outside_course`.
9. **Step 0 proves the whole path first, then compares models.** For 10 concepts: explain, generate practice, two-call check, seal, then render a correct page and a page with one planted slip from the practice problem's own worked steps with the existing fixture renderer (`server/eval/make_course_fixtures.py`), and run both through the real `handleWatch` with the sealed reference at the course tier. Measured: caught on the right line, false alarms, references accepted and rejected. Checker diagnostics also include 10 references with one wrong middle step and 5 ambiguous statements, not only wrong final answers. These are diagnostics, not pass thresholds; whether the path is good enough is judged from the watch results and from reading the 10 lessons. Only then is gpt-6-luna compared with gpt-6.1-sol for generation.
10. **Removed:** the "I could follow it" and "Lost me" buttons and `lesson_rated`; the revenue comparison per 20 minutes (counted minutes are not wall-clock minutes, `server/lib/students.ts:58`); the claim that Release log privacy is proved by a Debug run (Release keeps the existing `logsWords` gate and its unit test; a Release log capture waits for the paid account's build path).
11. **Latency is measured on the iPad**, Start tap to panel drawn (`lesson_requested` to `lesson_shown`), not from the server p90.
12. **Before deploy, refresh**: deployed SHA from `/api/health`, the ElevenLabs allowance for the current period, and the Vercel plan's function limit (11 functions after this).
13. **Device builds:** the same path as the own-problem QA round; whatever signing path that round settles is reused here.

## Acceptance (checked on the real iPad)

1. Edward names a concept he has not studied. An explanation starts within 10 s: at most 4 short steps plus one worked example.
2. The explanation sits in a panel that stays until he dismisses it. It is set in type by the existing math renderer, not drawn as ink.
3. Follow-up questions remember the conversation (the last 8 turns).
4. A "your turn" problem on that concept comes next. It is generated with its own worked solution and final answer, so the watch path has a reference and the answer-leak guard works. It is watched exactly like a bank problem.
5. The tutor never states the final answer before he tries.

## Why (evidence)

- **Teaching is out of scope today.**
  - Version one is "practice only: no lectures" (`docs/plan.md:11`).
  - Explaining concepts is listed as out of scope (`docs/plan.md:115`).
- **Answers are too short to teach.**
  - A spoken question gets "two or three plain sentences" (`server/lib/policy.ts:144`).
  - The page reader answers in "under 70 words" (`policy.ts:222`).
  - A written hint is at most 8 words (`policy.ts:29`).
- **Tap-to-talk has no memory.**
  - `AskRequestSchema` has no earlier turns (`server/lib/ask.ts:16-26`).
  - `buildAskPrompt` sends only the latest transcript (`policy.ts:242-250`).
  - Consult already takes `recent`, at most 8 turns (`server/lib/consult.ts:14-17, 28`). That is the pattern to copy.
- **The answer disappears.**
  - It shows as a banner for 20 s: `setStatus(response.answerText, seconds: 20)` (`ios/PencilTutor/Session/TutorSession.swift:1354`).
  - A timer then clears it (`TutorSession.swift:1372-1382`).
- **There is nothing to look at.**
  - The tutor can only put a red ellipse and an 8-word hint on the page.
  - The typeset renderer exists but only the problem card uses it: the notation reader is `ios/PencilTutor/Core/MathMarkup.swift:18-29`, the wrapping layout is `ios/PencilTutor/Views/ProblemCardView.swift:3-6`, and the card cuts a prompt into words and stacked fractions at `ProblemCardView.swift:98-112`.
- **Live voice is out of reach for this plan.**
  - The one conversation that taught (session `2026-11-14T01-48-59`, "that undoes the times four") used live voice.
  - Live is off unless a code's plan has `live: true` (`docs/plan.md:248-250`, `server/lib/gate.ts:124-126`).
  - It costs US$0.05 a minute, which is US$3 an hour (`docs/plan.md:262-264`).
  - Edward's price is US$20 a month for 8 hours (his figure on 2026-11-28; `docs/plan.md:197` still says CA$19). That is US$2.50 per counted hour, less than live alone costs. So teach mode uses the base voice and never opens live.
- **The own-problem plumbing is ready.**
  - `resolveProblem` already takes `own:<course>` plus `problem_text` (`server/lib/problems.ts:45-78`).
  - `referenceBlock` switches between the reference branch and the no-reference branch (`policy.ts:91-108`).
  - `revealsAnswer` skips only an empty answer (`server/lib/decision.ts:25-30`). A generated problem with a real `final_answer` therefore gets the leak guard back at once (`decision.ts:46`).
- **Ask and consult have no leak guard.** They return the model's text as it came (`ask.ts:88-97`, `consult.ts:75-85`).
- **A checked reference saves money.**
  - With no reference, gpt-6.1-sol caught 40 of 42 planted mistakes with 0 of 13 false alarms on real pages, but costs about 17 times gpt-6-luna (`docs/evals/2026-11-28-no-reference-eval.md`).
  - With a checked reference, the practice page runs at the course's tier like any bank problem. That is luna for every course today (plan.md amendment 18).
- **How bank problems are checked.**
  - Each course has a hand-written sympy check per problem, run offline (`shared/courses/calculus-1/verify.py:1-17`: "recomputes the answer from the prompt's own function/numbers"). The checks sit in a `CHECKS` registry keyed by problem id: 70 in calculus-1 and 70 in discrete-math.
  - The server runs Node only (`server/package.json`; `server/vercel.json` covers `api/*.ts`).
  - The iPad "only ever sees the prompt; solutions live on the server" (`ios/PencilTutor/Core/Models.swift:43`).

## How generated problems and solutions are checked (decision)

**Decision:** a second model call on the server, the checker. It is the advanced ask model (gpt-6.1-sol).

- It first solves each problem blind, from the statement alone.
- Then it compares its answer with the proposed final answer, deciding whether the two are mathematically equivalent.
- Then it checks each proposed step.
- Output: `{own_answer, equivalent, single_answer, first_wrong_step}`.
- A problem is "checked" only when `equivalent` and `single_answer` are both true and `first_wrong_step` is null.

**Why not sympy on the server.**
- The repo has no general sympy checker. Each bank problem has its own hand-written function.
- A runtime check would need either a parser from free-text maths (`x²`, `lim(x→−3)`, `√(…)`) to sympy, or the model writing sympy code for the server to run. The first is a project of its own. The second means running model-written code on the server.
- Either way it adds a Python runtime to a Node-only deployment.

**Why not skip checking.**
- The watch path trusts the reference. A wrong reference turns correct work into false alarms, which the watch policy calls "the worst failure" (`policy.ts:16`).
- In the no-reference eval, every false alarm traced back to a statement that did not match the page (`m5-26`, `fm11-39`).

**Where sympy still counts.** Step 0 calibrates the checker against bank problems that sympy has already verified, offline, so the checker's error rate is measured, not assumed.

**When the check fails.**
1. The practice problem is generated and checked once more.
2. If it fails again, the practice problem goes out as an own problem with no reference, which is the measured path. It is labelled `reference: unchecked`, and the card says "I couldn't double-check this one, so I'll work it out as you go."

**The lesson's example** is checked in the same checker call as the practice problem (one call, two items). It shows "Checking the example..." until the result arrives. On a disagreement it shows "A second check got a different answer here; ask me about it."

## Step 0: measure before choosing the model (R38)

- **New script** `server/eval/run-teach.ts`.
  - 10 concepts from Edward's college courses (calculus-1, linear-algebra, discrete-math; for example integration by parts, eigenvalues, induction, row reduction, modular inverses).
  - Each goes through the real `handleTeach` (explain, then practice) at `TEACH_LEVEL` `high_school` (luna) and at `advanced` (sol).
  - It records server latency, tokens, cost from `pricing.ts`, step counts and checker labels.
- **Checker calibration on sympy-verified ground truth.**
  - 20 bank problems from calculus-1 and discrete-math, each passing its own `verify.py`, sent to the checker as they are. It should agree on all of them.
  - The same 20 with one planted change to the final answer (sign flip, off by one, wrong constant). It should disagree.
- **Size:** about 100 model calls, under US$1.
- **Choice rules.**
  - The checker is accepted if it agrees on at least 19 of 20 and rejects at least 18 of 20.
  - `TEACH_LEVEL` is the cheapest level whose explain p90 is 8 s or less (leaving 2 s for the network and drawing), whose practice problem passes the check on the first try at least 9 of 10 times, and whose example passes at least 9 of 10 times.
  - If explain p90 is over 8 s, retry once with `ASK_EFFORT` set to `low`.
  - If nothing meets the rules, stop and report.
- **Output:** results go to `docs/evals/<date>-teach-eval.md`. Edward reading the 20 lessons breaks a tie; it is not a gate.

## What: server

- **New `POST /api/teach`** (`server/api/teach.ts` → `server/lib/teach.ts`). It uses the same gate (roles `ask` and `stt`), the same failure labels and `audienceFor(course)` (`policy.ts:67`). Prompts live in a new `server/lib/teach-policy.ts`. The body names an `action`:
  - **`explain`**: `{session_id, course, concept}`, where `course` must be a known slug (otherwise 422 `unknown_course`) and `concept` is 1 to 200 characters, treated as student content.
    - Returns `{is_math, title, steps, example: {prompt_parts, steps, final_answer}, spoken}`.
    - Each step and example line is `prompt_parts` (`text` and `frac` items, the bank's shape, read by `PromptPart` in `Models.swift:4-40`) written in the notation `MathMarkup` reads.
    - The server trims to 4 steps and 6 example lines and logs `steps_trimmed`. `spoken` is at most 2 sentences.
    - When `is_math` is false, the reply is "I can teach maths topics only."
    - Metered as a `question`.
  - **`followup`**: `{course, concept, lesson_text (at most 3,000 characters), recent (at most 8 turns, each at most 400 characters, the consult `TurnSchema`), question (text) or audio_base64 (transcribed with `runTranscription`), problem_ref?}`.
    - Returns `{transcript?, answer_text}`: at most 4 short sentences, which may include one line of maths.
    - Metered as a `question`.
  - **`practice`**: `{course, concept, lesson}`.
    - It generates one problem (`prompt_plain` up to 300 characters, `prompt_parts`, 2 to 8 worked steps, `final_answer` written in full as `x = 4`, not `4`). The problem must differ from the example.
    - It runs the checker on the example and the practice problem together, and retries once as described above.
    - Returns `{example_checked, problem: {id: "own:<course>", prompt_plain, prompt_parts}, problem_ref | null, reference: "checked" | "unchecked", attempts}`.
    - It calls `meterActivity(..., "question", null)`: a prefetch is not student work, so it charges 0 s.
- **Sealed reference** (new `server/lib/seal.ts`, `node:crypto` AES-256-GCM, about 30 lines).
  - `problem_ref` holds `{course, sha256(normalized prompt), worked_solution, final_answer, exp: 24 h}`, encrypted with `TEACH_SEAL_KEY`.
  - Why sealed and not plain: the iPad never holds a readable solution (`Models.swift:43`), and an unsealed reference field would let a request place any text in the prompt's "reference" block.
  - Without the key, `practice` answers 503 `teach_unavailable` ("TEACH_SEAL_KEY is not set") and `explain` still works.
  - In scripted mode (refused in production, `config.ts:140-144`) a fixed test key is used.
- **The reference reaches the watch path.**
  - `watch`, `ask` and `consult` accept an optional `problem_ref` (at most 6,000 characters).
  - The handlers open it first; `resolveProblem(id, text, reference?)` stays pure.
  - A valid reference whose course and text match gives `{id: "own:<slug>", prompt_plain, worked_solution, final_answer, course, teach: true}`. It has no `own` flag, so `referenceBlock` takes the reference branch, the tier comes from the course (`levelOf`), and `finalizeDecision` checks for leaks again.
  - A missing, invalid or expired reference falls back to the own problem it is today, logged as `reference: rejected_<label>`.
  - `problemFields` gains `problem_kind: teach`.
  - Heartbeat needs no change (`checkProblemId` already accepts `own:<slug>`).
  - Live is not touched: the voice never sees a solution (`policy.ts:154-155`).
- **Ask remembers.** `AskRequestSchema` gains `recent` (at most 8 turns, the same schema as consult). When it is not empty, `buildAskPrompt` adds "The conversation so far, most recent last".
- **Leak guard on spoken answers.** For a `teach` problem, an `ask` or `consult` answer, or a `followup` answer when `problem_ref` was sent, that contains the final answer (`revealsAnswer`) is replaced with "Give it a try on the page first. I'll check each line as you write." It is logged as `answer_withheld`.
- **Health.** `/api/health` gains `teach_ready` (whether the key is present, never the key).
- **Logs are labels and counts only.**
  - Logged: `action`, `course`, `concept_chars`, `is_math`, `steps`, `example_lines`, `recent_turns`, `question_chars`, `answer_chars`, `checker` (`agree`, `disagree`, `not_single`, `malformed`), `example_check`, `attempts`, `reference`, and the tokens and estimated cost of each call (`usageFields`, prefixed `gen_` and `check_`).
  - Never logged: the concept, the lesson or the problem text.

## What: iPad

- **Entry.**
  - A second row in every course's list, under "My own problem" (`ProblemListView.swift`, the other branch's `OwnProblemRow`): "Learn something new".
  - It opens a sheet copied from `OwnProblemSheet`: one field ("What do you want to learn?", 1 to 200 characters), Start disabled while empty, and Cancel.
  - Start pushes `LessonScreen(course, concept)`. The new route case goes in `CourseRoute`.
- **`LessonSession`** (new `Session/LessonSession.swift`, an `ObservableObject`) owns the lesson, every turn, `recent` (the last 8, each capped at 400 characters), the practice prefetch and its state.
  - It reuses `AudioRecorder` and `env.speech` (the base voice: ElevenLabs, then OpenAI, then the device voice).
  - It does not touch `LiveVoice`.
- **`LessonScreen`** (new `Views/LessonScreen.swift`).
  - It shows "Putting a lesson together..." at once.
  - When the lesson arrives: the panel appears, `spoken` is spoken, and the practice prefetch starts.
  - Bottom bar, each control 44 pt: the mic (tap-to-talk) and an "Ask a follow-up" text field, both going to `followup`, plus "Your turn" (shows "Getting a problem ready..." until the practice arrives) and the buttons "I could follow it" and "Lost me" (log only).
  - Every follow-up question and answer is added to the panel and spoken. Nothing on it times out.
- **`LessonPanel`** (new `Views/LessonPanel.swift`) shows the title, the steps, the example with "Checking..." or "Checked", and the conversation. It stays until its 44 pt close button is tapped.
  - For the type, it reuses the card's path. The card's `Piece` builder and `FlowLayout` (`ProblemCardView.swift:84-112`) move into a shared `MathParagraph(parts:size:)`, so the card and the panel draw maths one way.
  - Follow-up answers are plain text read by `MathMarkup.parse`.
- **Your turn.**
  - Pushes `ProblemScreen(problem:env:courseTitle:lesson:)` with `Problem(id: "own:<slug>", promptPlain:, promptParts:)` plus a new `problemRef: String?`.
  - It is the normal watched page: a fresh canvas, the same look rules, "Not a mistake", "Check my work".
  - A "Lesson" button in the action pill reopens the panel as a 360 pt side panel with a close button.
  - An unchecked problem shows the line about working it out as you go.
- **TutorSession** gets three small edits, made after `own-problem` merges because that branch rewrites the file:
  - `init` takes `lesson: LessonSession? = nil`.
  - Watch (`:1018`), ask (`:1336`) and consult (`:844`) send `problemRef`.
  - Ask sends `lesson.recent` as `recent` and adds the question and answer to the lesson, so answers given on the practice page also stay in the panel. `problem_opened.kind` becomes `teach`.
- **Wire and client.**
  - `WireTypes.swift`: `WatchRequest`, `AskRequest` and `ConsultRequest` gain `problemRef` (`problem_ref`, left out when nil); `AskRequest` gains `recent`; three new teach request and response pairs.
  - `TutorClient` gains `teachExplain`, `teachFollowup` and `teachPractice`, with default implementations in a protocol extension that throw. The test fakes in `TutorSessionDisputeTests`, `AllowanceTests`, `ProblemBankTests` and `WireAndSnapshotTests` then still compile.
  - `HTTPTutorClient` posts to `api/teach` with a 45 s timeout. `MeteredTutorClient` passes the allowance through.
  - `ScriptedTutorClient` returns a fixed lesson and practice, as the scripted server does. The practice id waits on every look, like own problems.
- **Logs.** `lesson_requested` (course, concept_chars), `lesson_shown` (latency_ms, steps, example_lines, model), `lesson_followup` (input voice or typed, chars, recent_turns, latency_ms), `practice_ready` (reference, attempts, example_checked, latency_ms), `practice_started`, `lesson_panel_closed`, `lesson_panel_reopened`, `lesson_rated` (followed or lost). Words appear only where Debug already keeps them (`TutorSession.logsWords`).

## Cost per teach session (estimated from `server/lib/pricing.ts`)

Token counts are assumptions until step 0 measures them. Rates per million tokens: luna US$0.10 in and US$0.50 out; sol US$2 in and US$10 out. Per-look costs come from the no-reference eval.

| item | luna (`TEACH_LEVEL` high_school) | sol (advanced) |
|---|---|---|
| Explain (about 650 in, 850 out) | $0.0005 | $0.0098 |
| Practice generation (about 800 in, 700 out) | $0.0004 | $0.0086 |
| Checker, sol, example plus practice (about 1,100 in, 900 out) | $0.0112 | $0.0112 |
| 5 follow-ups, text only (about 1,400 in, 250 out each) | $0.0013 | $0.0265 |
| Practice page: 15 looks plus 3 asks at the course tier (luna, with reference) | $0.005 | $0.005 |
| **Models** | **about $0.018** | **about $0.061** |
| Voice, about 2,500 characters at $0.04 per 1,000 (ElevenLabs, `docs/plan.md:257`; not in `pricing.ts`) | $0.10 | $0.10 |
| **Per session (about 20 minutes)** | **about $0.12** | **about $0.16** |

- Worst case, both checks fail: one more generation and check (about $0.012), then 15 looks on sol (about $0.066). Total about $0.25.
- Transcription for voice follow-ups is not priced in `pricing.ts` (`docs/plan.md:258`).
- For comparison: live voice for the same 20 minutes is $1.00, and the session's share of US$20 for 8 hours is about $0.83. Live stays out.

## Not in this plan

- Live voice in teach mode.
- Explanations drawn as tutor ink or handwriting.
- A LaTeX or KaTeX engine.
- Streaming the lesson text.
- sympy at runtime.
- Saving lessons between opens, or putting them in tutor memory.
- More than one practice problem, or "harder" and "easier".
- Teaching from a photo or from Edward's concept notes (`docs/plan.md:115`).
- Any change to `LiveVoice` or the dispute flow.
- Concepts outside the chosen course.
- Progress tracking.

## Tests

**Server**, `tsx --test`, touched files only (`server/node_modules/.bin/tsx --test server/test/teach.test.ts`, plus `own-problem.test.ts` for the `resolveProblem` change). The full suite runs on `server.yml` CI.
- Seal: round trip; rejects tampered, expired, other-course and other-text references.
- `resolveProblem`: a valid reference gives a `teach` problem with the reference branch, the course tier and the leak check; an invalid one falls back to own with its label.
- Explain: schema; trims to 4 steps and 6 lines; the not-maths path; 422 for an unknown course or a concept over 200 characters; the log line holds no concept text.
- Followup: 422 for more than 8 turns; the turns reach the prompt in order; audio goes through transcription.
- Practice: the checker agrees (reference returned); disagrees then agrees (2 attempts); disagrees twice (`unchecked`, no reference); a disagreement on the example.
- Ask: `recent` in the prompt. Ask and consult on a teach problem: `answer_withheld`.
- `hours_used_up` blocks teach. Scripted mode answers without a key. `/api/health` reports `teach_ready`.

**iPad unit tests (XCTest)**
- `LessonSession` with a fake client: the lesson fills the panel; the panel is still there after a simulated 120 s (no timer); `recent` keeps the last 8 turns, in order, each capped at 400 characters; follow-ups are added; "Your turn" stays disabled until the practice arrives; the unchecked note appears.
- Wire: snake_case keys; `problem_ref` left out when nil.
- A practice `Problem` sends `problem_ref` on watch, ask and consult; ask sends `recent`.
- `MathParagraph` loses no character of a parts line.

**CI** (`ios.yml`, run by hand when the branch is ready): build, unit tests, and one UI test against the scripted client. It covers: the row, the sheet, Start opens the lesson, the panel shows, "Your turn" opens the page with the card text, and "Lesson" reopens the panel. Locally, run at most one touched test at a time with `-only-testing:`.

**Real iPad** (QA receipts: screenshots plus the session log):
- 5 concepts Edward has not studied. For each, `lesson_shown.latency_ms` is 10 s or less, there are at most 4 steps and one example, and the panel is still there after 2 minutes and after follow-ups.
- 5 follow-ups in a row that depend on each other. Edward judges them, and the Debug log has the words.
- The practice problem with one planted slip: the circle sits on the right line.
- Asking "what's the answer?" before trying is withheld.
- A Release log holds no concept text.

## Build and deploy

- **iPad**, as in the own-problem plan: CI builds only an unsigned simulator app. The device build is one incremental Debug `xcodebuild` per QA round on the Mac, signed with Edward's free identity and installed with `devicectl`.
- **Server:**
  - The coordinator generates 32 random bytes and adds them with `vercel env add TEACH_SEAL_KEY production` piped from the generator, never printed or saved (zero clicks for Edward).
  - No migration.
  - After merge, deploy `main` (production is 31 commits behind, so `own-problem` goes first) with `vercel deploy --prod` from `server/`.
  - `/api/health` must show the merged commit and `teach_ready: true`.

## Risks

- **Shared blind spots.** If the checker and the generator miss the same thing, a wrong reference passes and turns correct work into false alarms. Mitigations: step 0 calibration on sympy-verified problems, "Not a mistake", and counting disputes per `reference: checked` problem.
- **The leak guard is a substring match.** A short answer can withhold something harmless, and an equivalent form ("0.5" for "1/2") slips through. The generator must write answers in full, and `answer_withheld` is counted.
- **Latency.** Sol may miss 10 s; step 0 decides, with low effort as the fallback.
- **The concept is a typed instruction channel.** It is capped at 200 characters, treated under the student-content rule, and gated by `is_math`.
- **ElevenLabs capacity.** 157,028 credits a month that cannot be extended (`docs/plan.md:268-270`), and about 2,500 characters a session, so about 60 sessions use up the month. Only `spoken` and the answers are voiced.
- **Key rotation** sends open practice pages back to the own-problem path. They keep working, without a reference.
- **The provider may not enforce array length limits.** The server trims and logs.
- **The device build expires** every 7 days (`README.md:59`).
- **TutorSession conflicts.** The teach edits there come after `own-problem` merges.
- **Vercel functions** go from 10 to 11. The Hobby plan limit was not checked.
- **The price is not settled.** `docs/plan.md:197` says CA$19 and Edward says US$20. This plan uses US$20 and does not decide it.
