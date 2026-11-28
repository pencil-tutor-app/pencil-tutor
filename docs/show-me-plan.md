# Plan: "Show me how" (solve it for a lost student, then one like it)

Revision 3, 2026-11-28. Review 1 REDO (the voice cannot author a routing marker), review 2 CUT; the cuts are folded in under "Decisions of Revision 3" and win over anything below them. Branch `show-me`.

## Decisions of Revision 3 (after review 2, CUT)

1. **Compile on CI, sign on the Mac.** CI builds an unsigned device (iphoneos) Debug app as an artifact; the Mac only re-signs it with the free Apple ID's identity and an Xcode-made provisioning profile and installs it with `devicectl`. Only if re-signing cannot be made to work does the Mac fall back to one incremental build, and the report says so with the reason.
2. **One spoken confirmation, sent only once the solution is on screen.** The voice-triggered path answers the delegation once, after the panel shows the steps. While loading it says nothing; on `not_checked` or a failure it answers with that ("I couldn't work this one out with confidence") and never says the solution is on screen.
3. **Voice acceptance stays pending until a real session records** speech, consult `show_me`, the panel shown and the walkthrough spoken. The agent's receipts cover the button path; Edward's next session is the voice receipt.
4. **Real checker run on hard cases.** Before merge, run the real solve path (generator plus check) on the inconsistent system and the free-variable system in the linear-algebra bank, submitted as own problems, plus one single-answer system; record verdicts and cost in `docs/evals/`.
5. **Blank pages reach the router.** `TutorSession` returns before consult on an empty canvas (`TutorSession.swift:847`); a delegation on a blank page must still reach consult so "I have no idea where to start" works. Tested through `TutorSession` with an empty canvas.
6. **The check keeps its flags.** `checkStatement` returns `not_single` before looking at a wrong step (`teach.ts:148`). It is changed to return the comparer's flags; solve accepts only `equivalent && first_wrong_step == null`. Tested: several answers with a wrong step is rejected.
7. **Old apps keep working.** The `SHOW_ME` consult rule is added only when the request carries `show_me_ok: true`, which only the new app sends. Older apps get today's consult unchanged, so they never receive an empty answer (`WireTypes.swift:176`, `TutorSession.swift:897`).

## Owner decision (Edward, 2026-11-28, after his first real session)

"When a student has really no idea and just asks for help, then it will solve it for them. That's how I teach them too... You give them a problem, they can't solve it. You solve it for them. You give them a slightly different one, and then they'll be able to solve it." And: the voice saying "page watcher" is unacceptable.

This reverses "never give the final answer or write out a corrected line, even if they ask for it" (`server/lib/policy.ts:166`, `ASK_POLICY`, `CONSULT_POLICY`, `LIVE_TEACH_NOTE` at `policy.ts:210`) for one case only: the student asks to be shown or says they have no idea. Hints stay the default for automatic looks and "check my work".

## Evidence

Session `844b4264` on Edward's iPad, 2026-11-28 13:33 UTC, bank problem `la-02`, live voice. The raw log stays off this public repo (same rule as `docs/evals/2026-11-28-real-ipad-sessions.md`); the numbers below are read from it (`devicectl device copy from ... Documents/session-2026-11-28T13-33-27.756Z-844b4264.jsonl`).

- The student said four times that he had no idea or asked to be shown (`student_said` at +41 s, +134 s, +149 s, +167 s). The voice gave one hint four times ("use the first row to clear the entries below the first pivot") and said "I can't write on your page".
- The voice said "let me ask the page watcher" and "the page watcher just looked". The words come from our context lines (`ios/PencilTutor/Live/LiveProtocol.swift:127`, `:129`, `:137`) and from "a page reader can look at the page for you" in `LIVE_TUTOR_TEMPLATE`.
- A manual check at revision 45, the same revision as the previous look, said "Looks good so far. Keep going." (`LiveProtocol.swift:132`) while the student was stuck.
- Jargon first: "pivot", "leading one", "back-substitution"; the student asked what back-substitution is.
- The 14 to 16 s from `live_consult_answered` to the voice speaking is not latency. `tutor_said` is logged when a turn ENDS (`ios/PencilTutor/Live/LiveVoice.swift:491-496`), and those two turns were 273 and 217 characters, about 15 s of speech each: the voice read the whole matrix back from the page report. This is a read of the log code, not a measurement of first-audio latency, which the logs cannot show.

## What the student gets

1. **Show me how**, a button in the problem page's action pill on every problem (bank, own, practice), and the same action when the student asks the voice. It opens a side panel with the statement, the worked steps and the answer, typeset by `MathParagraph`. The panel is a new small view built from the lesson panel's parts (`MathParagraph`, the 360 pt side-panel frame and its 44 pt close button); it does not use `LessonSession`, conversation history or example-checking state (`LessonPanel.swift:10` is coupled to `LessonSession`).
2. **The voice walks through it.** When the panel opens with live connected, the app pushes the steps as `thinking` lines, split on step boundaries so no append passes the 1,200-character clip (`LiveProtocol.swift:98`), then one `commentary` line: walk through the steps one at a time in plain words, check they follow each one, then offer a similar problem. Without live, the base voice says one short line.
3. **Try one like it**, a button at the bottom of the panel. It calls the existing `practice` action and swaps the page to the result as a normal practice page (`Problem.practice`, sealed reference, watched like any page). If the student is lost again there, Show me how works there too.

## How a spoken request reaches Show me how

The voice cannot send the app a marker: a delegation carries only an id and a target (`LiveProtocol.swift:39`), and the app builds the question from the student's own transcript (`LiveVoice.swift:353`). So the decision is made where the student's words already go:

- Live template: when the student says they have no idea or asks to be shown, generate `<|SpawnThinking|>` (do not repeat a hint). That delegation goes to `/api/consult` with the student's words, as today.
- `CONSULT_POLICY` gains one rule: when the student's words ask to be shown how, ask for the solution, or say they have no idea where to start, answer with exactly `SHOW_ME` and nothing else. `handleConsult` maps an answer that is `SHOW_ME` after trimming to `{show_me: true, answer_text: ""}` and logs `consult_show_me`; any other answer goes through as today.
- The iPad, on `show_me: true`, opens Show me how, answers the delegation with "The worked solution is on their screen now; walk them through it" and logs `show_me_requested {source: voice}`. The button logs `source: button`. Tap-to-talk `/api/ask` is unchanged; the button covers a student without live.

## Server: one new action on `/api/teach`, no new function

- `action: "solve"`, request `{session_id, course, problem_id, problem_text?, problem_ref?}`, resolved with `resolveRequestProblem` as consult does.
  - Bank: return the stored `worked_solution` and `final_answer` as they are, however many steps (`la-02` has 7; `ExampleSchema` allows 6, so the reply has its own schema and `ExampleSchema` is not used). No model call.
  - Practice: the sealed reference's checked steps and answer. No model call.
  - Own: generate `{steps (1 to 12 lines of at most 200 characters), final_answer}` with the advanced model, then `checkStatement`. For solve the check accepts when `equivalent` is true and `first_wrong_step` is null, whatever `single_answer` says, because an own problem may have several answers or none (the solver already returns every answer in one string, `teach-policy.ts:116`). Otherwise 200 `{solution: null, reason: "not_checked"}` and the iPad says "I couldn't work this one out with confidence. Try again?" with a Try again button. No unchecked fallback.
  - Reply `{solution: {steps, final_answer} | null, reason, model, latency_ms}`; metered as a question like `practice`; logs `kind: bank|practice|own`, checker verdict, `est_cost_usd`; no text.
- Try one like it: the existing `practice` action, `concept` = "problems like this one", `lesson_text` = the statement plus the shown steps, no `example` (the shown solution is already checked or stored; sending it as an example would recheck it with two more calls, `teach.ts:342`). The practice prompt already asks for the same concept and level with different numbers (`teach-policy.ts:95`). Known limit: `same_as_example` is not in play without an example and catches only identical text anyway (`teach.ts:364`); the generator is told the statement it was given is the one to differ from, through `lesson_text`.

## Voice wording (server `policy.ts`, iPad `LiveProtocol.swift`)

- The voice speaks as if it looks itself. `LIVE_TUTOR_TEMPLATE`: "you cannot see their page... a page reader can look at the page for you" becomes "you can look at their page when you need to (that is your backend tool)"; add "Never mention a page reader, a watcher, a helper or anyone else; say 'let me look', and talk about the page as something you saw." The three context lines lose "the page watcher".
- Plain words first: "Say the idea in everyday words first; give the maths term once, after."
- `LIVE_TEACH_NOTE` and the practice context line (`LiveContext.practice`) gain one exception: once the worked solution is on screen, walk through it. The server's pre-attempt answer guard stays for hints and asks.
- No read-back. `LIVE_TUTOR_TEMPLATE` tells the voice not to read back what is on the page unless the student asks or it matters for the point, and to keep spoken page results to the verdict plus one next step (the page report itself still names what it saw, so the voice has the evidence).
- Manual check on an unchanged page with nothing wrong: "Nothing new since I last looked. Want me to show you how?" instead of "Looks good so far. Keep going."

## Tests

- Server: `solve` for bank (`la-02`, all 7 steps), practice (valid, expired), own (agree; disagree; equivalent with `single_answer` false accepted; provider failure), scripted; consult maps `SHOW_ME` to `show_me: true` and leaves other answers alone.
- iPad, through the real path: a `LiveVoice` test where the transcript holds "I have no idea, show me", a delegation fires, a scripted consult replies `show_me: true`, and the session opens the panel and answers the delegation (extends the pattern at `LiveVoiceTests.swift:184`); the step-splitting keeps every append under 1,200 characters; no context line contains "watcher" or "page reader"; the panel in each state (loading, shown, not_checked, failed) in the gallery tests; a UI test with the scripted client: Show me how, then Try one like it lands on a practice page that takes ink and gets a look.
- Prompt-string tests prove only that the words are in the instructions, not how the voice teaches; that is judged on the device.
- Full runs on GitHub CI; locally only the test files touched.

## Rollout

1. Merge on green; deploy the server (`vercel deploy --prod` from `server/`), check `/api/health` version.
2. The CI artifact `PencilTutor-iphoneos-Debug-unsigned`, re-signed on the Mac and installed with `devicectl` (Decision 1; done 2026-11-28, no local build). The side panel is being replaced by tutor ink on the page: `docs/tutor-ink-plan.md`.
3. Silent device QA with screenshots and the session log: `la-02` via the button, the panel, Try one like it, ink on the new page, a look. Silent mode skips live (`TutorSession.swift:596`), and no audio may play through the Mac, so the spoken path is proved on device only by Edward's own session; the agent's receipts cover the button path and the unit test covers the voice routing.

## Docs to update with the code

`docs/plan.md` (the principle), `server/README.md` (`solve`, consult `show_me`, the live rules), `docs/ipad-teach-mode.md` (a Show me how section), `docs/how-to-run.md` (QA steps).
