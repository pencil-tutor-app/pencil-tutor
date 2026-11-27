# Plan: teach mode (learn a new concept, then try one yourself)

Revision 3, 2026-11-28 (both halves are built; the clauses that Revision 2 and the build replaced are deleted, so this file reads as one plan). Branch `teach-mode`, built on `own-problem` (the server work `f670b15` and the iPad work `dad376b`). Line numbers in `ios/` are from the working tree and will move.

Owner goal (Edward, 2026-11-28): "I'm learning some brand-new concept... this just helps with homework and helps me with brand-new stuff too." This is job B. Job A is `docs/own-problem-plan.md`.

## Decisions of Revision 2 (2026-11-28, after plan review 1, REDO)

1. **Checking is two calls, and the first one is blind.** Call 1 (solver, advanced ask model, `ASK_EFFORT_ADVANCED` is the effort knob, not `ASK_EFFORT`) gets only the canonical statement and returns its own final answer. Call 2 (comparer, same model) gets the statement, the generator's steps and final answer, and the solver's answer, and returns `{equivalent, single_answer, first_wrong_step}`. The reference is accepted only when both agree, the answer is single, and no step is wrong.
2. **One canonical statement.** The generator returns `prompt_plain` only, in the notation `MathMarkup` already reads; the iPad renders it with the same parser the problem list and card use (`ProblemListView.swift:171`, `ProblemCardView.swift`). No separate `prompt_parts` is generated, so what is shown and what is checked are the same string (the mismatch behind the m5-26 and fm11-39 false alarms cannot happen).
3. **No unchecked fallback, no automatic regeneration.** If the check fails, `practice` answers 200 with `{problem: null, reason: "not_checked"}` and the iPad shows "I couldn't make a practice problem I'm sure of. Try again?" with a Try again button. Each tap is one generate plus two checks. Logged `practice_not_checked`.
4. **A rejected example is withheld, not shown with a warning.** The lesson shows its steps; the example slot says nothing and `example_withheld` is logged. The example is checked by the same two-call path, in parallel with practice generation.
5. **No truncation.** Step and line limits are in the structured-output schema; an answer over the limit is a failed call (`teach_too_long`) and the iPad says "That came out too long, try again." Nothing is cut mid-explanation.
6. **Answers before an attempt are refused by state, not by text matching alone.** The iPad decides it from geometry only (`docs/ipad-teach-mode.md`, `Core/Attempt.swift`): at least one line group that is not crossed out and has stayed unchanged across one look. Until it has one, ask, consult and followup requests about the practice carry `attempted: false`, and the server tells the model it must not give the final answer or any line that contains it. The text guard stays as a second layer and gets a spoken-form normalizer (number words zero to twenty, "equals", "minus", "plus", "times", "over", "squared") with unit tests on both "x = 4" and "x equals four". An expired or invalid reference is a 422 `practice_expired` (the iPad offers a new practice), never a silent fall back to an own problem, so the guard is never lost. Expiry is 7 days.
7. **Live voice follows the normal rule.** The practice page is a normal `ProblemScreen`, so live starts only for a code whose plan has live (`TutorSession.swift:596`), exactly as on any page. Edward approved live for his own code on 2026-11-28; the US$20 plan's codes have it off. The lesson screen itself never starts live. The "teach never opens live" line below is withdrawn.
8. **Course fit.** `explain` returns `fits_course` besides `is_math`; a concept outside the course gets "That belongs to another course; pick it there" and `concept_outside_course`.
9. **Step 0 proves the whole path first, then compares models.** For 10 concepts: explain, generate practice, two-call check, seal, then render a correct page and a page with one planted slip from the practice problem's own worked steps with the existing fixture renderer (`server/eval/make_course_fixtures.py`), and run both through the real `handleWatch` with the sealed reference at the course tier. Measured: caught on the right line, false alarms, references accepted and rejected. Checker diagnostics also include 10 references with one wrong middle step and 5 ambiguous statements, not only wrong final answers. These are diagnostics, not pass thresholds; whether the path is good enough is judged from the watch results and from reading the 10 lessons. Only then is gpt-6-luna compared with gpt-6.1-sol for generation.
10. **Removed:** the "I could follow it" and "Lost me" buttons and `lesson_rated`; the revenue comparison per 20 minutes (counted minutes are not wall-clock minutes, `server/lib/students.ts:58`); the claim that Release log privacy is proved by a Debug run (Release keeps the existing `logsWords` gate; CI builds the Release configuration, runs one lesson UI test on it and checks that its session log holds no words, `ios/Scripts/check_release_log.py`).
11. **Latency is measured on the iPad**, Start tap to panel drawn (`lesson_requested` to `lesson_shown`), not from the server p90.
12. **Before deploy, refresh**: deployed SHA from `/api/health`, the ElevenLabs allowance for the current period, and the Vercel plan's function limit (11 functions after this).
13. **Device builds:** not settled here. CI builds only an unsigned simulator app. A signed device build needs Edward's identity and must not run on the laptop (standing rule); the coordinator picks the cloud path.

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
- **Live voice is out of reach for the lesson screen.**
  - The one conversation that taught (session `2026-11-14T01-48-59`, "that undoes the times four") used live voice.
  - Live is off unless a code's plan has `live: true` (`docs/plan.md:248-250`, `server/lib/gate.ts:124-126`).
  - It costs US$0.05 a minute, which is US$3 an hour (`docs/plan.md:262-264`).
  - Edward's price is US$20 a month for 8 hours (his figure on 2026-11-28; `docs/plan.md:197` still says CA$19). That is US$2.50 per counted hour, less than live alone costs. So the lesson screen uses the base voice and never opens live; the practice page follows the normal live rule (decision 7).
- **The own-problem plumbing is ready.**
  - `resolveProblem` already takes `own:<course>` plus `problem_text` (`server/lib/problems.ts:45-78`).
  - `referenceBlock` switches between the reference branch and the no-reference branch (`policy.ts:91-108`).
  - `revealsAnswer` skips only an empty answer (`server/lib/decision.ts:25-30`). A generated problem with a real `final_answer` therefore gets the leak guard back at once (`decision.ts:46`).
- **Ask and consult had no leak guard** (before this work they returned the model's text as it came); they now replace an answer that states a teach problem's final answer.
- **A checked reference saves money.**
  - With no reference, gpt-6.1-sol caught 40 of 42 planted mistakes with 0 of 13 false alarms on real pages, but costs about 17 times gpt-6-luna (`docs/evals/2026-11-28-no-reference-eval.md`).
  - With a checked reference, the practice page runs at the course's tier like any bank problem. That is luna for every course today (plan.md amendment 18).
- **How bank problems are checked.**
  - Each course has a hand-written sympy check per problem, run offline (`shared/courses/calculus-1/verify.py:1-17`: "recomputes the answer from the prompt's own function/numbers"). The checks sit in a `CHECKS` registry keyed by problem id: 70 in calculus-1 and 70 in discrete-math.
  - The server runs Node only (`server/package.json`; `server/vercel.json` covers `api/*.ts`).
  - The iPad "only ever sees the prompt; solutions live on the server" (`ios/PencilTutor/Core/Models.swift:43`).

## How generated problems and solutions are checked (decision)

**Decision:** two model calls on the server, both on the advanced ask model (gpt-6.1-sol, effort `ASK_EFFORT_ADVANCED`), whatever `TEACH_LEVEL` says for generation.

1. **The blind solver** gets only the statement and returns its own final answer.
2. **The comparer** gets the statement, the generator's steps and final answer, and the solver's answer, and returns `{equivalent, single_answer, first_wrong_step}`.

A problem is "checked" only when both agree: `equivalent` and `single_answer` are true and `first_wrong_step` is null. The lesson's example goes through the same two calls, in parallel with the practice generation. There is no regeneration and no unchecked fallback.

**Why not sympy on the server.**
- The repo has no general sympy checker. Each bank problem has its own hand-written function.
- A runtime check would need either a parser from free-text maths (`x²`, `lim(x→−3)`, `√(…)`) to sympy, or the model writing sympy code for the server to run. The first is a project of its own. The second means running model-written code on the server.
- Either way it adds a Python runtime to a Node-only deployment.

**Why not skip checking.**
- The watch path trusts the reference. A wrong reference turns correct work into false alarms, which the watch policy calls "the worst failure" (`policy.ts:16`).
- In the no-reference eval, every false alarm traced back to a statement that did not match the page (`m5-26`, `fm11-39`). Generating one statement, `prompt_plain`, and checking that same string removes that mismatch.

**Where sympy still counts.** Offline, to check the check: in step 0 the statements and solutions the models produced are recomputed with sympy before any page is drawn (done for three concepts, `docs/evals/2026-11-28-teach-flow.md`).

**When the check fails.** `practice` answers 200 with `{problem: null, reason: "not_checked"}`. The iPad shows "I couldn't make a practice problem I'm sure of. Try again?" and each tap is one generation plus two checks. A rejected example is withheld: the lesson shows its steps and the example slot stays empty, never an example with a warning.

## Step 0: prove the path, then measure (R38)

**Done, small (2026-11-28, `docs/evals/2026-11-28-teach-flow.md`, script `server/eval/run-teach-flow.ts`):** three concepts through the real handlers: explain, practice, the two-call check, the seal, then the real `handleWatch` with the sealed reference on a drawn correct page and a drawn page with one planted slip (3 of 3 silent, 3 of 3 caught on the right line); a forced reference rejection; answer-withholding checks with an equivalent spoken form; the statements and solutions recomputed with sympy first. 53 model calls, about US$0.08. It found two real defects in the answer guard, fixed.

**Still to do, in this order:**
1. The wider sample: about 10 concepts from Edward's college courses (calculus-1, linear-algebra, discrete-math), same flow. Measured: caught on the right line, false alarms, references accepted and rejected. Diagnostics, not pass thresholds: 10 references with one wrong middle step and 5 ambiguous statements, so the check is shown wrong inputs and not only wrong final answers. Whether the path is good enough is judged from the watch results and from reading the lessons.
2. Only then compare gpt-6-luna with gpt-6.1-sol for the lesson and the practice generation (`TEACH_LEVEL`), and try `ASK_EFFORT_ADVANCED` set to `low` for explain latency.
3. Latency is judged on the iPad (`lesson_requested` to `lesson_shown`), not from the server.

## What: server

Built; the wire contract is in `server/README.md` ("Teach problems", `POST /api/teach`).

- **`POST /api/teach`** (`server/api/teach.ts` → `server/lib/teach.ts`). Same gate (roles `ask` and `stt`), same failure labels, `audienceFor(course)`. Prompts, schemas and every limit live in `server/lib/teach-policy.ts`. The body names an `action`:
  - **`explain`** `{session_id, course, concept}`: `course` a known slug (else 422 `unknown_course`), `concept` 1 to 200 characters, student content. Returns `{is_math, fits_course, message, title, steps (at most 4), example: {prompt_plain, steps (at most 6), final_answer}, spoken (at most 2 sentences), model, latency_ms}`, all plain text in the notation `MathMarkup` reads. Not maths: "I can teach maths topics only." Another course: "That belongs to another course; pick it there." (`concept_outside_course`). Counted as a question.
  - **`followup`** `{course, concept, lesson_text (at most 3,000), recent (at most 8 turns of at most 400), question or audio_base64, problem_text?, problem_ref?, attempted?}`. Returns `{transcript, answer_text}`, at most 4 short sentences. Counted as a question.
  - **`practice`** `{course, concept, lesson_text, example?}`: generates one problem (`prompt_plain` at most 300 characters, 2 to 8 worked steps, `final_answer` in full as `x = 4`, different from the example), runs the two-call check on it and on the example, and returns `{example_checked, problem: {id: "own:<course>", prompt_plain} | null, problem_ref | null, reason: null | "not_checked"}`. It charges 0 seconds (`meterActivity(..., "question", null)`).
- **No truncation.** The limits are in the structured-output schema. An answer over a limit is a failed call: 502 `teach_too_long`, and the iPad says "That came out too long, try again." Nothing is cut.
- **Sealed reference** (`server/lib/seal.ts`, `node:crypto` AES-256-GCM). `problem_ref` holds the course, the statement, the worked solution, the final answer and a 7-day expiry, encrypted with `TEACH_SEAL_KEY` (32 random bytes). Sealed, not plain: the iPad never holds a readable solution (`Models.swift:43`), and an unsealed field would let a request put any text in the prompt's "reference" block. Without the key, `practice` is 503 `teach_unavailable` and `explain` still works. Scripted mode uses a fixed key (refused in production, `config.ts`).
- **The reference reaches the watch path.** `watch`, `ask`, `consult`, `live-session` and `followup` accept an optional `problem_ref` (at most 6,000 characters). `resolveRequestProblem` (`lib/teach-ref.ts`) opens it; `resolveProblem` stays pure. A valid reference for the same course and statement gives a teach problem `{id: "own:<slug>", prompt_plain, worked_solution, final_answer, course, teach: true}`: no `own` flag, so `referenceBlock` takes the reference branch, the tier comes from the course (`levelOf`), and the leak checks run. An expired, invalid, other-course or other-statement reference is **422 `practice_expired`, never a silent fall back to an own problem**; the iPad offers a new practice. `problemFields` logs `problem_kind: teach`. Heartbeat needs no change.
- **Ask remembers.** `AskRequestSchema` gains `recent` (at most 8 turns, the consult schema); when it is not empty `buildAskPrompt` adds "The conversation so far, most recent last".
- **No answer before an attempt, by state and by text.** `ask`, `consult` and `followup` take `attempted` (missing counts as false); until it is true the prompt forbids the answer, any line that contains it and the result of any step. The text guard (`lib/spoken.ts`) is the second layer: for a teach problem an answer that states the final answer, written or spoken (number words, "equals", "minus", "times", "over", "squared", "cubed", "prime", brackets and "the quantity" ignored), is replaced with "Give it a try on the page first. I'll check each line as you write." and logged `answer_withheld`. The same check covers the hints of a watch interrupt and a reworded hint for a teach problem.
- **Live.** The voice answers without asking the page reader and its words never reach the server, so the pre-attempt rule is in its instructions for a teach problem (`LIVE_TEACH_NOTE`, `buildLiveInstructions`); delegated reports come from `consult`, which has the guard. Live still follows the normal plan rule (only codes whose plan has live).
- **Health.** `/api/health` gains `teach_ready` and `teach_level` (never the key).
- **Logs are labels and counts only.** `action`, `course`, `concept_chars`, `is_math`, `fits_course`, `steps`, `example_lines`, `recent_turns`, `question_chars`, `answer_chars`, `checker` (`agree`, `disagree`, `not_single`, `wrong_step`, `malformed`, `same_as_example`), `example_check`, `reference`, and the tokens, time and estimated cost of every call (prefixes `gen_`, `example_solve_`, `example_compare_`, `check_solve_`, `check_compare_`). Events: `practice_not_checked`, `example_withheld`, `concept_outside_course`, `answer_withheld`, `teach_too_long`. Never logged: the concept, the lesson, the problem or any answer.

## What: iPad

Built; the details are in `docs/ipad-teach-mode.md`.

- **Entry.** A second row in every course's list, under "My own problem": "Learn something new" (`ProblemListView.swift`). It opens a sheet with one field ("What do you want to learn?", 1 to 200 characters), Start (off while empty) and Cancel. Start pushes `LessonScreen` (`CourseRoute.lesson`).
- **`LessonSession`** (`Session/LessonSession.swift`, an `ObservableObject`) owns the lesson, every turn, `recent` (the last 8, each capped at 400 characters), the practice problem and its state. It reuses `AudioRecorder` and `env.speech` (the base voice). It never touches `LiveVoice`.
- **`LessonScreen`** shows "Putting a lesson together..." at once. When the lesson arrives the panel appears, `spoken` is spoken and the practice problem starts being made. Bottom bar, each control 44 pt: the mic (tap to talk), an "Ask a follow-up" field, and "Your turn" ("Getting a problem ready..." until the checked problem arrives; "Try again" when the server could not check one). Every question and answer joins the panel and is spoken. Nothing on it times out.
- **`LessonPanel`** (`Views/LessonPanel.swift`) shows the title, the steps, the example and the conversation. It stays until its 44 pt close button is tapped (on the practice page; on the lesson screen Back leaves). The example is read through `LessonSession.visibleExample` only: "Checking the example..." while its check is pending, nothing if it was rejected, so an unchecked example never flashes. The text is `prompt_plain`-style plain text read by `MathMarkup`, drawn by the shared `MathParagraph` (the card's word and fraction builder and `FlowLayout`, moved out of `ProblemCardView`), so the card and the panel draw maths one way.
- **Your turn** pushes the normal `ProblemScreen(problem:env:courseTitle:lesson:)` with `Problem.practice(...)`: id `own:<slug>`, `promptPlain` from the server, and the sealed reference in `problemRef`. It is the normal watched page. A "Lesson" button in the action pill reopens the panel as a 360 pt side panel with a close button. When the server answers `practice_expired`, the page offers "New practice problem" (never a quiet fall back to an own problem).
- **Attempted.** The page counts as attempted when it holds at least one line group that is not crossed out and has stayed unchanged across one look (geometry only, no handwriting recognition; conservative: a copied problem statement counts). Ask and consult carry `attempted`; the live voice is told on connect and on every change; follow-ups from the panel carry it too. There are no ratings.
- **`TutorSession`**: `init` takes `lesson: LessonSession? = nil`; watch, ask and consult send `problemRef`, live-session sends it too; ask sends the lesson's `recent` and adds the exchange to the lesson; `problem_opened.kind` is `teach`.
- **Wire and client.** `WatchRequest`, `AskRequest`, `ConsultRequest` and `LiveSessionRequest` gain `problemRef` (`problem_ref`, left out when nil); `AskRequest` gains `recent` and `attempted`, `ConsultRequest` gains `attempted`; three teach request and reply pairs. `TutorClient` gains `teachExplain`, `teachFollowup` and `teachPractice` with throwing defaults in a protocol extension, so the existing fakes compile. `HTTPTutorClient` posts to `api/teach` with a 45 s timeout; `ScriptedTutorClient` returns a fixed lesson and a fixed practice problem.
- **Logs.** `lesson_requested`, `lesson_shown` (latency_ms from Start tap to panel), `lesson_followup`, `practice_ready`, `practice_not_checked`, `example_withheld`, `practice_started`, `practice_expired`, `attempt_changed`, `lesson_panel_closed`, `lesson_panel_reopened`. Words appear only where Debug already keeps them (`TutorSession.logsWords`).

## Cost per teach session (measured, `docs/evals/2026-11-28-teach-flow.md`)

From the API's usage in one small real run (3 concepts), reasoning tokens inside the output, priced by `server/lib/pricing.ts` (luna US$0.10 in and US$0.50 out per million; sol US$2 and US$10). The check is four sol calls: two for the example, two for the practice problem.

| item | luna (`TEACH_LEVEL` high_school) | sol (advanced, default) |
|---|---|---|
| Explain | $0.0003 | $0.0047 |
| Practice generation | $0.0002 | $0.0030 |
| Check, four sol calls | $0.0036 | $0.0036 |
| 5 follow-ups, text only | $0.0011 (estimated; follow-ups were measured on sol only) | $0.0147 |
| Practice page: 15 looks plus 3 asks at the course tier (luna, with reference) | $0.0042 | $0.0042 |
| **Models** | **about $0.009** | **about $0.030** |
| Voice, about 2,500 characters at $0.04 per 1,000 (ElevenLabs, `docs/plan.md:257`; not in `pricing.ts`; not measured) | $0.10 | $0.10 |
| **Per session (about 20 minutes)** | **about $0.11** | **about $0.13** |

- A failed check costs the next Try again tap one generation plus four check calls, about $0.0065 with sol generation.
- Transcription for voice follow-ups is not priced in `pricing.ts` (`docs/plan.md:258`).
- The numbers of follow-ups, looks and asks per session are assumptions; the per-call costs are measured.
- For comparison: live voice for the same 20 minutes is $1.00, and the session's share of US$20 for 8 hours is about $0.83.

## Not in this plan

- Live voice on the lesson screen itself (the practice page follows the normal live rule).
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

**Server**, `tsx --test`, touched files only (`server/node_modules/.bin/tsx --test server/test/teach.test.ts`, plus `own-problem.test.ts`, `consult.test.ts`, `live.test.ts`, `server.test.ts`, `record.test.ts` for the shared code). The full suite and the typecheck run on `server.yml` CI. `teach.test.ts` (53 tests):
- Spoken form: number words, operators, "x = 4" and "x equals four", the two real model sentences, longer numbers not matching, a closing full stop, bank and own problems untouched.
- Seal: round trip; rejects tampered, other-key, junk, other-course, other-statement and expired (7 days) references; key formats; scripted key never in production.
- A reference on watch, ask, consult and live-session: the reference branch and course tier, `reference: accepted`, 422 `practice_expired` with its label and no model call for each bad reference, 503 `teach_unavailable` without a key, no reference stays an own problem.
- Ask and consult on a teach problem: `recent` in the prompt in order and counted in the log; more than 8 turns is 422; the pre-attempt and after-attempt notes; "x equals four" replaced and logged `answer_withheld`; a bank problem untouched.
- Live-session on a teach problem: the instructions carry `LIVE_TEACH_NOTE` and the statement, never the solution or the answer; a bad or expired reference is 422 and OpenAI is not called.
- Explain: the lesson, not maths, another course, an answer over a limit is 502 `teach_too_long` and never trimmed, 422 for an unknown course or a bad concept, no concept text in the log, metering and `hours_used_up`, scripted mode.
- Followup: turns in order, more than 8 turns or a long turn is 422, exactly one of question and audio, audio through transcription, the guard with a reference, nothing withheld without one.
- Practice: both calls agree (reference opens to the checked solution); the solver is blind; the check runs on the advanced model; disagree, not single and wrong step each give `not_checked` with one generation and no regeneration; malformed output; the same problem as the example; a rejected example is withheld while the practice problem goes out; a provider failure is an error, not a rejection; 503 without a key; no seconds charged.
- `/api/health` reports `teach_ready`.

**iPad unit tests (XCTest)**, one touched class at a time with `-only-testing` (`docs/ipad-teach-mode.md`, Tests): `LaunchOptionsTests` (every sound is muted under XCTest, run first), `AttemptRuleTests` and `PracticeSessionTests` (blank, partial, written, erased and crossed-out pages; the live context), `LessonSessionTests` (the lesson fills the panel and nothing on it changes by itself; the example is hidden while pending and withheld if rejected; `recent` keeps the last 8 turns, in order, each capped at 400 characters; "Your turn" waits for the checked problem; Try again is one request), `TeachWireTests` (snake_case, `problem_ref` left out when nil, ask carries `recent` and `attempted`, `MathParagraph` loses no character).

**CI** (`ios.yml`, run by hand when the branch is ready): build, unit tests, the UI tests against the scripted client (`LessonUITests`: the row, the sheet, Start shows the panel, Your turn opens the page with the card text, Lesson reopens the panel, a follow-up joins the panel, a non-maths concept is refused), and the Release step: build Release, run one lesson UI test, check its session log holds no words. Locally, never a UI test and never the full suite.

**Real iPad** (QA receipts: screenshots plus the session log):
- 5 concepts Edward has not studied. For each, `lesson_shown.latency_ms` is 10 s or less, there are at most 4 steps and one example, and the panel is still there after 2 minutes and after follow-ups.
- 5 follow-ups in a row that depend on each other. Edward judges them, and the Debug log has the words.
- The practice problem with one planted slip: the circle sits on the right line.
- Asking "what's the answer?" before trying is withheld.

## Build and deploy

- **iPad**: CI builds only an unsigned simulator app and runs the tests and the Release log check. A signed device build is not settled here (it needs Edward's identity and must not run on the laptop); the coordinator picks the cloud path.
- **Server:**
  - The coordinator generates 32 random bytes and adds them with `vercel env add TEACH_SEAL_KEY production` piped from the generator, never printed or saved (zero clicks for Edward).
  - No migration.
  - After merge, deploy `main` (production is 31 commits behind, so `own-problem` goes first) with `vercel deploy --prod` from `server/`.
  - `/api/health` must show the merged commit and `teach_ready: true`.

## Risks

- **Shared blind spots.** If the checker and the generator miss the same thing, a wrong reference passes and turns correct work into false alarms. Mitigations: the blind solver (it never sees the generator's steps), the step 0 diagnostics (wrong middle step, ambiguous statements), "Not a mistake", and counting disputes per problem with `reference: accepted`.
- **The leak guard is a text match, with a spoken-form reader.** A short answer can withhold something harmless; an equivalent written form ("0.5" for "1/2") still slips through; the first version missed what the real model says for an expression and was fixed after the step 0 run, so a new phrasing can still get past it. The generator writes answers in full, `answer_withheld` is counted, and the model is also told by state (`attempted`) not to give the answer. The live voice's own words cannot be checked on the server at all; only its instructions protect that route.
- **Latency.** Measured on sol with no effort set: explain 7.9 to 13.3 s of server time over 6 runs, 4 of 6 under 10 s. The luna and low-effort comparison is step 0's second part; the iPad measures the real figure.
- **The concept is a typed instruction channel.** It is capped at 200 characters, treated under the student-content rule, and gated by `is_math`.
- **ElevenLabs capacity.** 157,028 credits a month that cannot be extended (`docs/plan.md:268-270`), and about 2,500 characters a session, so about 60 sessions use up the month. Only `spoken` and the answers are voiced.
- **Key rotation** makes every open practice page answer 422 `practice_expired`; the iPad offers a new practice problem.
- **Whether the provider enforces the schema limits is untested.** The server never trims: an answer over a limit is a failed call (`teach_too_long`). The real run never produced one, so that path is proved only with a fake provider.
- **The device build expires** every 7 days (`README.md:59`).
- **A copied statement counts as an attempt.** The attempted rule is geometry only and cannot tell a problem copied onto the page from work.
- **Vercel functions** go from 10 to 11. The Hobby plan limit was not checked.
- **The price is not settled.** `docs/plan.md:197` says CA$19 and Edward says US$20. This plan uses US$20 and does not decide it.
