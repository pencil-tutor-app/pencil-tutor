# Plan: the tutor writes on the page (Show me how, on the canvas)

Revision 3, 2026-11-28. Review 1 REDO, review 2 CUT; the decisions below win over anything after them.

## Decisions of Revision 3 (after review 2, CUT)

1. **The correction check sees what is drawn.** The second call gets the tagged page picture, the problem statement, every earlier line of the student's work as read, the original flagged line, the chosen tags and the exact replacement, and answers whether striking those tags and writing that replacement makes the line right given the work so far. It does not only compare two transcribed lines.
2. **Every character is drawable.** The inventory counts characters as well as constructs (bank solutions hold `¬`, `∧`, `∨`; `ink_synth.py:97` throws on an unmapped character). A CI test fails on any bank or eval-solution character without a glyph; missing glyphs are added as strokes. At runtime an unmapped character is drawn as a small box and logged, never thrown.
3. **Fallback text wraps** to the line width; nothing is cut and it is not forced onto one line.
4. **Tutor context is the whole visible tutor work.** `tutor_wrote` carries every tutor line on the page, numbered stably (bounded by the schema: 12 solution steps plus corrections, 200 characters each), not the last 8.
5. **Pointing is scored against annotated targets.** For each fixture used, the builder looks at the tagged picture and writes the correct tag set by hand in an annotation file before running the model; the score is model tags against those, and the drawn strike and replacement are checked in rendered pictures. Real handwriting: the tagged pictures of tonight's real la-02 page (`844b4264`, kept off the repo) are inspected for tag sanity; Edward's next sessions give real mistakes.
6. **Re-anchor moves everything tutor-side.** Pending correction targets, tag boxes and an in-progress write-on animation are translated with every re-anchor (`TutorSession.swift:304`, `:419`) or discarded and asked again; never drawn at stale coordinates.
7. **The correction snapshot is aimed.** The `correct` request captures the flagged line and the lines it depends on explicitly, not the newest-ink window (`PageSnapshot.swift:180`).
8. **The voice gets one step at a time.** The whole-solution push and walkthrough line (`TutorSession.swift:975`) are replaced: the voice is given only the steps already written, plus the one being written, so narration cannot outrun Next.
9. **Spoken behaviour is labelled unverified** (Next by voice, interruption, pacing) until an audible run is recorded; silent visual receipts are required either way. Branch `tutor-ink`. Replaces the Show me how side panel (`docs/show-me-plan.md`); `solve`, the voice routing (`show_me`) and Try one like it stay.

## Owner goal (Edward, 2026-11-28, after seeing the panel)

"Show me how it can actually correct, write on the screen (literally write on the screen), and accurately point out what you've been wrong about. Literally, a friend collaborates with you on a canvas, not showing another wall of text."

## Evidence

- The panel is correct but is a block of text beside the page (`docs/evals/assets/show-me-la-02-panel.jpg`).
- Marks today circle a whole line (`ios/PencilTutor/Views/MarksOverlay.swift:61`); the watch reply names a line, never a term.
- Pen-stroke text already exists: Hershey single-stroke glyphs and layout in `tools/handwriting/ink_synth.py`, and script-to-`PKStroke` conversion in `ios/PencilTutor/Debug/InkReplay.swift:114`.
- `MathNode` has no fraction node and does have operator limits (`ios/PencilTutor/Core/MathMarkup.swift:4`).
- No speech-finished event is decoded from the live session (`LiveProtocol.swift:9`); `tutor_said` is logged when the output transcript finishes, which is not proven to match audible playback.

## What ships (smallest version that does all three jobs)

### 1. One tutor ink layer
- A second, non-interactive `PKCanvasView` above the student's canvas, same content size, zoom and offset, holding only tutor strokes in teal. It moves with the page on every re-anchor, and page growth counts tutor ink bounds too (`TutorSession.swift:218`, `:304`).
- Strokes come from the existing Hershey glyphs: the glyph data is bundled as JSON and laid out in Swift, ported from `ink_synth.py`; the `PKStroke` conversion is extracted from `InkReplay.swift` into shared code. The debug replay controller is not shipped in Release.
- Layout covers what solutions actually contain. Inventory first: every `worked_solution` line in the 1,024 bank problems plus the generated solutions in `server/eval/results/show-me-*.jsonl`, counted by construct (powers, subscripts, roots, `a/b` fractions, matrices, operator limits, Greek, arrows). Anything the layout cannot draw falls back to writing it as plain characters on one line, never dropping it; the fallback is logged with the construct label.
- Written stroke by stroke. The speed is measured on device and set so a 40-character step takes 2 to 4 s.
- Snapshots to the watcher stay student-ink only. The tutor's written steps and corrections go to consult and ask as text, a `tutor_wrote` list (at most 8 lines), so a follow-up question about "your second line" makes sense.
- One "Clear tutor ink" button in the action pill. Logged: `tutor_ink_started/finished {purpose, steps, strokes, ms, fallbacks}`; no text.

### 2. Show me how, written on the page
- Where: from the top of a blank page; otherwise under the student's last line, left-aligned with it.
- Pace: one step is written, the voice explains that step (live: one commentary per step; without live, the base voice says one short line per step). The next step comes on **Next** (a pill button) or when the student says "next" / "go on" (the voice is told to delegate that, and consult answers `show_me_next` the way it answers `show_me`). Automatic advance on speech end is not built until a signal is proven.
- The panel is removed. Try one like it stays as the voice's offer at the end and a pill button after the last step.

### 3. Point and correct, on request, for a flagged line
- When a circle is on line N and the student asks to be shown (button or voice), the iPad sends a `correct` request: the page picture with numbered tags under each ink cluster of line N (clusters split at horizontal gaps; a fraction or matrix line falls back to one tag per stacked group), line N-1's and line N's tag boxes, and the drawing revision.
- The server's advanced model returns `{tags, replacement}`: which tags are wrong and what to write instead. A second, separate call checks the edit: given the previous line as read and the corrected line, does the corrected line follow? Only an edit that passes is returned; otherwise `not_checked` and the voice explains the slip in words with the existing circle.
- The iPad applies it only if the revision is unchanged (the student has not edited since; otherwise it asks for a fresh look first): a teal strike through the tagged clusters, the replacement written just above them, and the voice explains. This also fixes the stale-routing trap: `show_me` and `correct` both check the revision before drawing (`TutorSession.swift:884`).
- Automatic term tags on every watch look are deferred. Existing circles stay as they are.

## Measured before merge

- Correction diagnostic on the planted-mistake fixtures (`server/eval/fixtures/courses-messy`, `planted` and `wrong_line` in the manifest) and their correct twins, through the real handlers: right tags (scored per page against `planted`, written down), replacement right, check accepted or refused, false corrections, latency, cost. Synthetic pages are a diagnostic only (`make_course_fixtures.py:27`).
- Real handwriting: Debug builds already save each page picture sent to watch and consult. Edward's first sessions with this build are the real measurement; the eval doc lists what they show.
- Ink legibility: rendered pictures of every construct in the inventory, long expressions included, looked at and kept as assets.

## Tests

Layout per construct (boxes and stroke counts) and the fallback; tutor layer follows re-anchor and zoom; snapshots hold no tutor strokes; Next and "next"; Clear tutor ink; `correct` wire with and without tags; revision-changed refusal; consult `tutor_wrote`.

## Device QA

Silent, with `--qa-show-me` extended to press Next: la-02 written on a blank page, then on a page with replayed ink holding one planted slip (`--replay-ink`), flagged, then corrected. Screenshots and a screen recording of the pen. The audible run (voice explaining each step, interruption, "next", writing beside tutor ink) is Edward's session; silent mode skips live voice.

## Docs

`docs/ipad-teach-mode.md` (Show me how section rewritten), `server/README.md` (`correct`, `show_me_next`, `tutor_wrote`), `docs/how-to-run.md` (QA), `docs/show-me-plan.md` (pointer).
