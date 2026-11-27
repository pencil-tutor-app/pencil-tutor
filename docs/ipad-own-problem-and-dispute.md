# iPad: "My own problem" and "Not a mistake"

Build notes for plan steps 2 and 3 (`docs/own-problem-plan.md`), 2026-11-28, written with the code. Server work (resolver, `problem_text` handling, the `disputed` history entry) is a separate change; this file says what the app sends and does.

## My own problem (plan step 2)

- First row of every course's problem list (`ProblemListView.swift`, `ownProblemRow`). It opens a sheet with one text field (`ownProblemField`), a character count, Cancel and Start. Start stays off while the cleaned text is empty. Line breaks become spaces, the ends are trimmed, and the field stops at 500 UTF-16 units (the way the server counts), never cutting a character in half (`OwnProblemText`, `Models.swift`).
- Start closes the sheet, then pushes `ProblemScreen` with `Problem.own(courseSlug:text:)`: id `own:<course slug>`, `promptPlain` = the typed statement, so the card shows it like a bank prompt. Cancel opens nothing.
- `TutorClient` requests carry `problem_text` (snake_case) for own problems only: watch, ask, consult and live-session (`WireTypes.swift`, `TutorSession.swift`, `LiveVoice.swift`). It is left out of the JSON for a bank problem. Heartbeat sends only the id (`own:<slug>`), as the plan says.
- The scripted client (`--scripted-client`) has no new branch: it already waits on every id except `u3-04` (`OwnProblemTests.testTheScriptedTutorAlwaysWaitsOnAnOwnProblem`).
- Log lines (labels, ids, counts only, never the typed text): `own_problem_started {course, chars}`, `own_problem_cancelled {course}`, `problem_opened {problem_id, kind: own|bank}`.

## Not a mistake (plan step 3)

### The button

The hint callout now holds the hint words and, under them, a "Not a mistake" button (44 pt tall, `notAMistakeButton`). `MarksOverlay` no longer switches hit testing off for the whole overlay; the circle, the hint words, the card behind them and its outline are each switched off, so the button is the only thing that takes a touch. `MarksOverlayHitTestTests` hosts the real overlay over a probe view and samples every 4 pt of a 1180 x 820 screen: only a strip about 44 pt tall and no wider than the callout answers, the circle's stroke falls through, and with no marks nothing is hit. Drawing, scrolling and pinching beside the button therefore reach the canvas by construction; `OwnProblemUITests` checks drawing beside the button and across the hint words on CI.

The callout used to assume 64 pt. It is now measured (words plus gap plus button plus padding, about 120 pt for a two line hint; the 120 pt guess is only used until the first layout), and kept at least 24 pt (or the real bottom inset) above the bottom edge so the button is not under the home-indicator swipe zone. `MarkCalloutTests` places a 260 x 120 callout against circles on every row and width of a 1080 x 810 screen: it stays whole on screen and clear of that strip; a wide circle near the bottom puts the callout above it.

### What a dispute is keyed on

Not `Mark.inkSignature` (rounded stroke boxes: a page re-anchor changes it, a rewrite need not) and not `InkStroke.id`. Checked:

- `InkStroke.id` is the stroke's position in `PKDrawing.strokes`. A re-anchor (`drawing.transformed`) keeps the order, so ids survive it but the boxes do not. Erasing an earlier stroke renumbers every later id. Ids alone are not identity (`InkIdentityTests.testIdentitySurvivesAnEarlierStrokeBeingErasedWhichRenumbersTheIds`).
- What does survive a re-anchor, an erase elsewhere and renumbered lines is the stroke's start time (`PKStrokePath.creationDate`, one per pen-down) plus its width and height. PencilKit keeps the start time through `transformed` (`testIdentitySurvivesAPageReanchorThatMovesEveryStroke`, run on the simulator).
- So a dispute holds an `InkIdentity`: the sorted list of those fingerprints for the strokes of the disputed line (`Core/InkIdentity.swift`). Two identities are the same ink only if they hold the same strokes (start times to the millisecond, sizes to a point).
- Added, erased or redrawn strokes make a different identity. A stroke redrawn in the very same place has a new start time, so it counts as an edit. Scaling a selection with the lasso changes the size, so it counts too. Moving a selection does not (position is not part of the identity).

### Tap, suppress, end

- Tap (`TutorSession.markNotAMistake`): the mark comes off; the ink under it (the line now under the mark's box, which is what the student sees) goes into the `DisputeBook`; log `mark_disputed {line, request_id, model, strokes, disputes, marks_left}`; history gets `{action: "disputed", line}` (the number the student saw; the server treats it as advice).
- Suppress (`applyInterrupt`): after the existing stale check, the flagged line's identity is compared with the book. A match drops the interrupt: nothing drawn, said or counted as an interruption (so the 45 s quiet time does not start), log `interrupt_suppressed_disputed` (the look's ids, the disputed line and request id; no text, not even the model's reason), and the history gets a `disputed` entry with the line number the server used this time. A look the student asked for (Check my work) still answers "Looks good so far" so silence does not read as broken. It does not matter how many looks have passed or how the lines are numbered (tests: 12 more looks, a line written above, a page re-anchor).
- End: a disputed stroke that is no longer on the page (erased or redrawn) ends the dispute (`disputes_ended`); Erase page ends all of them. Adding a stroke to the line gives the line a different identity, so the tutor may circle the extended line (the dispute stays and applies again if the extra stroke is erased).
- Limits: 40 disputes per problem screen (oldest forgotten first). Disputes live in memory for the screen; they are not saved between opens.

### The voice (`takeBackHint`, log `hint_taken_back {line, voice_still_had_this_hint, paths, live_told, consults_in_flight}`)

The screen remembers which mark's hint it last handed to a voice (`hintInVoice`). Only that mark's dismissal may stop the voice, so dismissing an older circle never cuts off a newer hint. For that mark:

| where the hint is | what happens | label in `paths` |
|---|---|---|
| held in `LiveVoice` behind a page report | dropped, release timer cancelled, `live_hint_dropped reason: disputed` | `held_dropped` |
| already sent to the live voice as commentary | cannot be recalled (see below); the live voice gets a quiet context line "line N is not a mistake, do not repeat it, stop if mid-sentence" | `sent_while_speaking_context_only` or `sent_already_said_context_only` (log `live_hint_retract_after_send`) |
| playing, or being fetched, on the base voice | `SpeechOutput.stopIfSpeaking(purpose: "hint")`, log `speech_stopped reason: hint_disputed` | `base_voice_stopped` |
| a page report still being read whose late answer goes to Live | the answer gets a note "the student marked line N as not a mistake" appended (log `live_consult_dispute_note`) | `consult_in_flight_will_carry_a_note` |

The live voice is always sent the context line, whichever case applies. Nothing pending logs `paths: nothing_pending`.

Not solved: audio the live model has already started cannot be cut. The five client event types the server lets through (`LiveClientEvent`) have no cancel, so a hint that is mid-sentence finishes and the model is told not to repeat it. Whether a context line makes the model stop mid-sentence is unverified; it needs the real iPad (play a hint, tap Not a mistake while it speaks, keep the audio and the session log). A cancel event would need a server allow-list change and OpenAI's documentation of one.

## Tests (unit, run on one iPad simulator with `-only-testing`)

- `InkIdentityTests`: identity through re-anchor, erase renumbering, a line written above, add/erase/redraw/scale; the book.
- `OwnProblemTests`: own `Problem` JSON round trip, text rules, `problem_text` on the four requests only for own problems, scripted client waits.
- `TutorSessionDisputeTests`: a real canvas and a fake tutor: dismiss, 12 more looks, line inserted above, page re-anchor, real edit, extended line, manual look, Erase page; `problem_text` on a real look; base voice stopped; older circle leaves the newer hint alone; hint already sent to Live; hint held behind a page report with the late report carrying the note.
- `LiveVoiceTests`: held, sent and nothing-to-take-back; live-session request carries the typed problem.
- `SpeechStopTests`, `MarkCalloutTests`, `MarksOverlayHitTestTests`.
- UI (CI only, not run on the laptop): `OwnProblemUITests`: the row is first and 44 pt tall, the sheet opens, Cancel closes it, Start is off while empty, Start opens the page with the typed text on the card; the Not a mistake button is at least 44 pt, clear of the bottom strip, ink beside it and across the hint words still draws, and tapping it takes the circle off.

## Not verified here

- The tap on the button and the pass-through under a real Apple Pencil (the unit hit test uses UIKit hit testing on the simulator; the UI test runs on CI).
- Voice stops (the live-voice cases use a fake transport; the base-voice case uses the device voice for a moment in the simulator).
- That the server accepts `problem_text` and the `disputed` history action (server change, not part of this one).
