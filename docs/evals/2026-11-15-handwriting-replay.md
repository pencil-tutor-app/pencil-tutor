# Handwriting replay: testing the whole app with no human (2026-11-15)

A way to test Pencil Tutor end to end with realistic handwriting, with nobody holding a Pencil and without XCUITest (which the
iPad blocks overnight: "Timed out while enabling automation mode"). A script makes the strokes, a Debug-only launch argument
draws them into the real canvas at human pace, a runner drives the iPad and scores the session log.

What runs for real: PencilKit stroke storage and `canvasViewDrawingDidChange`, `TutorSession` idle timing and look policy,
`LineGrouper`, `PageSnapshotter` (the picture sent to the models), the live production server and real (cheap tier) model calls,
the marks overlay and the spoken hint. What is skipped: the touch itself.

## How to run it

1. **Make the cases** (needs only Python 3; Pillow only for `preview`):

   ```
   python3 tools/handwriting/ink_script.py cases --out-dir /tmp/cases                        # 12 cases, brisk writer
   python3 tools/handwriting/ink_script.py cases --out-dir /tmp/cases-think --think 3 --suffix=-think   # same, 3x longer pauses
   python3 tools/handwriting/ink_script.py gen --course bc-math-9 --problem m9-07 --mistake-line 2 --seed 4 --out one.json
   python3 tools/handwriting/ink_script.py preview one.json one.png                          # look at the handwriting
   python3 tools/handwriting/ink_script.py plan --course calculus-1                          # problems whose solution is a clean page of equations
   ```

   `ink_script.py` takes the math steps of `worked_solution` from `shared/courses/<slug>/problems.json` (prose around them is
   dropped, because a student writes the math), writes them with `ink_synth.py`, and with `--mistake-line N` changes the last
   number on the right of the "=" on line N and carries the changed value into later lines where the old one appears. The ink
   script is JSON: `lines[].strokes[].points = [x, y, t, force]` (page points from the top-left of the canvas, seconds from the
   start), plus `expected` (`no_mistake`, or `mistake` with the line and the mutation). Cases are deterministic: same seed, same
   ink. `from-eval-manifest` turns a fixture from the `eval-courses` branch (`server/eval/fixtures/manifest.json`, BC Math 9
   equation pages with a known first wrong line) into an ink script; those use `u3-*` ids which are not in the course banks, so
   they were not run here.

2. **Build and install the Debug app on the iPad** (unlocked; the code is already in the Keychain from earlier runs):

   ```
   xcodegen generate --spec ios/project.yml --project ios        # then pass the team below; or edit project.pbxproj
   xcodebuild -project ios/PencilTutor.xcodeproj -scheme PencilTutor -configuration Debug -destination 'generic/platform=iOS' \
     -derivedDataPath ios/build -allowProvisioningUpdates DEVELOPMENT_TEAM=9AKCDYB7T4 -quiet build
   xcrun devicectl device install app --device 00008030-0002101902D0202E ios/build/Build/Products/Debug-iphoneos/PencilTutor.app
   ```

3. **Run:** `python3 tools/handwriting/run_device.py --cases-dir /tmp/cases --out-dir runs/today [--case ID ...]`.
   Per case it copies the script into the app container (`devicectl device copy to ... Documents/<file>`), launches with
   `--open-problem <id> --replay-ink <file> --replay-settle 20`, waits for the app's `replay_done` log line, pulls the new
   `session-*.jsonl`, the page pictures sent to the models (`page-*-watch-*.png`) and a screenshot of the whole screen
   (`screen-*.png`), and writes `score.json` and `results.json`. About 1.5 to 2 minutes a case. `--target sim --sim-udid <UDID>`
   runs the same on a booted simulator (see "not verified" below).

The app side is `ios/PencilTutor/Debug/InkReplay.swift`, entirely inside `#if DEBUG`, started by a three-line hook in
`InkCanvas.makeUIView`. Log events (labels and counts only, never the work's text): `replay_started`, `replay_stroke_batch`
(one per line), `replay_finished` (strokes drawn, lateness), `replay_screenshot`, `replay_done`, `replay_failed` with the reason.
The replay always draws with the plain black pen at the default width, whatever the rail was last set to. A scripted stroke
goes through the delegate's `canvasViewDidBeginUsingTool`, is added to the drawing as a real `PKStroke` when its pen-up time
arrives (PencilKit then calls `canvasViewDrawingDidChange` itself on iPadOS 26; an explicit call doubled `ink_changed`, 102
events for 51 strokes, so it was removed), then `canvasViewDidEndUsingTool`.

**Not in Release:** `LaunchOptions.replayInkFile` and `replaySettleSeconds` return nil/default under `#else`,
`InkReplay.swift` and `InkReplayTests.swift` are wrapped in `#if DEBUG`, the hook in `InkCanvas.swift` is wrapped in `#if DEBUG`.
`xcodebuild -showBuildSettings`: Debug has `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`; Release has none. (I did not build
Release and grep the binary.)

## Results: 24 runs on the real iPad (iPad 9th generation, iPadOS 26), 24 of 24 as planted

Two profiles per case: **brisk** (about 1 second between lines, so the tutor first looks after the last line) and **think**
(pauses 3x longer, a look after most lines). One problem per course, one correct page and one page with a planted mistake. "Mark"
is a `decision` with `action: interrupt` that was not discarded; "late" is seconds from the end of the wrong line to the mark.

| Course | Problem | Planted (line) | Brisk: looks, result, late | Think: looks, result, late | Server model ms |
|---|---|---|---|---|---|
| bc-math-5 | m5-26 | correct | 1 look, wait | 4 looks, all wait | |
| bc-math-5 | m5-26 | 30 x 4 ... 7 x 4 = 56 (3) | 1, mark on 3, 18.4 s | 2, mark on 3, 7.2 s | 3879 / 3445 |
| bc-math-9 | m9-07 | correct | 2, wait | 5, all wait | |
| bc-math-9 | m9-07 | (-2)^3 = -16 (2) | 1, mark on 2, 30.0 s | 2, mark on 2, 7.0 s | 4368 / 3525 |
| bc-pc-11 | pc11-24 | correct | 1, wait | 5, all wait | |
| bc-pc-11 | pc11-24 | (3) | 1, mark on 3, 22.9 s | 3, mark on 3, 6.5 s | 5474 / 2661 |
| bc-calc-12 | ca12-24 | correct | 2, wait | 4, all wait | |
| bc-calc-12 | ca12-24 | (3) | 1, mark on 3, 13.3 s | 3, mark on 3, 7.9 s | 4128 / 4327 |
| calculus-1 | c1-54 | correct | 2, wait | 4, all wait | |
| calculus-1 | c1-54 | 1/48 -> 1/58 (3) | 1, mark on 3, 31.7 s | 3, mark on 3, 7.1 s | 4133 / 3193 |
| linear-algebra | la-01 | correct | 1, wait | 5, all wait | |
| linear-algebra | la-01 | (3) | 1, mark on 3, 15.3 s | 3, mark on 3, 6.7 s | 3363 / 3131 |

Totals: 12 correct pages, 0 false alarms; 12 mistake pages, 12 marks on the planted line, 0 marks on an earlier line, 0 errors,
0 discards. Every strokes-drawn count equalled the `ink_changed` count (one per stroke) and the drawing's stroke count. The
mark reached the screen about 7 seconds after the wrong line in the think profile (2.5 s idle wait plus 2.7 to 5.5 s server
model time), which is usually after the student has started the next line (`mark_before_next_line_started` was false in all 12),
though before they finish the page. In the brisk profile the first look comes only after the last line, so the mark is 8 to 9
seconds after the last stroke.

The seed, mutation and written lines of each case are in `cases.json` made by the command above (not committed: it is
regenerated byte for byte).

## What the page images looked like

I read the page pictures the app sent to the models (`page-*-watch-*.png`, 1024x768, ink in black with the faint line numbers)
and the whole-screen screenshots. Both are in `docs/evals/assets/`.

- The strokes read as quick monoline handwriting: slanted, uneven size and baseline, slightly bowed strokes, "x" and "="
  drawn in two strokes. It is neat, rounder and more regular than a rushed student, and the strokes have constant weight.
- Fractions are stacked with a bar, exponents raised and small, a root sign with an overbar, and augmented matrices with
  tall brackets (checked in the preview image; no matrix case was run on the iPad). Stretched parentheses around a fraction
  came out thin and slanted and look like `|` on the page; the exponent `-2/3` is cramped. Best effort, as asked.
- `docs/evals/assets/c1-54-mistake-screen-with-mark.png` shows the real screen: ink, the red circle and the callout ("Recheck the
  derivative arithmetic") from the marks overlay.
- The expanded problem card covers the top of the page (about 170 points on a long prompt, which hid line 1 in the
  calculus screenshot). Scripts start 130 points down; a long prompt still covers some of the first line. The tutor was sent
  the picture of the ink, not the screen, so this did not change a result.

## Findings (leads, not defects: not traced beyond these logs, and the ink is synthetic)

- **Line grouping disagreed with the script in 5 of 24 runs** (`app_lines_seen` vs the lines written): m9-07 correct pages
  (6 for 5: the raised exponent in `(-2)^3` became its own line, label 3 sits on top of label 2 in
  `m9-07-correct-page-sent-to-model.png`), c1-54 mistake (4 for 5: the third and fourth lines, both with stacked fractions,
  merged into one line, so the circle in the screenshot wraps both), la-01 mistake and its think twin (7 for 6). The verdicts
  still passed because the model named a line inside the right region, but a line index drifting by one is the kind of bug
  that sends a circle to the wrong row. My exponents are a little more raised than real ones, so check with real ink before
  treating this as a `LineGrouper` bug.
- The same-ink rule held: no response was discarded in 24 runs because the student kept writing after a look.
- With the default 2.5 s idle wait, a student who writes a line and pauses under 2.5 s never gets a look mid-page (brisk profile:
  1 look, after the last line).

## What this cannot test

- Real Pencil pressure curves, tilt, hover, palm rejection, the Pencil's double tap and squeeze, finger scrolling and pinch
  while writing, and the touch path into PencilKit (`touchesBegan` is not called; `touch_began` diagnostics do not appear).
- Real student messiness: crossings-out, erasing, rewriting, writing outside the lines, side calculations, slanted pages,
  tiny or huge writing, letters that touch. The synthetic hand is consistent from line to line.
- Anything that needs a human voice (tap to ask, live voice) or reading the screen aloud. The hint is spoken by the iPad
  during the run; the replay does not check the audio.
- The simulator path (`--target sim`) is written but not run: a simulator has no student code in its Keychain and I did not
  go looking for one. Pass one through an environment variable (`--student-code-env`); it is never printed or written.
- A single course sample of one problem each; the planted mistake is a changed number, not a conceptual error such as a sign
  rule, and later lines are carried forward only where the old number appears again.

## Follow-up (2026-11-15, branch `line-grouping-and-card`): the three findings fixed, replayed on the iPad

Changes: `LineGrouper` rewritten (bands, valleys, small-mark attachment, tighter fraction detection), writing starts below the problem
card and a tutor mark is never left under it, and the card sets real maths (`docs/plan.md`, amendment 19).

**Replay, 38 runs on the iPad** (the original 24 plus 14 new: rational and integer exponents `pc11-13`, `m9-08`, `pc12-22`; stacked
fractions `m9-45`, `pc12-08`, `c1-60`; three cramped and wobbly pages, `--gap-scale 0.5 --jitter 1.6`, of `m9-07`, `pc11-24`, `c1-54`;
one matrix problem `la-12`). 38 of 38 passed: 16 correct pages with 0 false alarms, 22 mistake pages each marked on the planted line,
0 errors, 0 discards, one `ink_changed` per stroke.

| | Before (main) | After |
|---|---|---|
| Original 24 runs: app line count equals the lines written | 19 of 24 (device, count only) | 24 of 24 (device) |
| New 14 pages, strict check (each group holds one written line, count matches) | 1 of 14 (offline, real old `LineGrouper`) | 14 of 14 on device (count) and 14 of 14 offline (strict; a matrix counts as one line) |

"Before" for the 14 new pages could not be run on the device inside the 40 run budget, so it comes from the old `LineGrouper` source
compiled on the Mac and fed the same ink; the same harness reproduced exactly the five device disagreements listed above for the
original 24, so it is a faithful stand-in. The offline corpus (`ink_script.py stress`, 2,570 pages, strict check): 985 agree before,
2,404 after; at normal spacing 265 of 514 before, 505 after.

What the iPad screenshots show (in `assets/`): `c1-54-mistake-screen-after.jpg` (the first line starts below the card, the circle wraps line 3
only, where before it wrapped lines 3 and 4), `la-12-matrix-mistake-screen-after.jpg` (a matrix page: each equation with its matrix is one line,
the circle covers the whole matrix row), `m9-07-correct-page-sent-to-model-after.png` (the exponent in `(-2)^3` stays on line 2; before it
was line 3), `card-calculus-1-after.jpg` and `card-linear-algebra-after.jpg` (the card for sample prompts from the course banks, drawn on a
simulator by `CardGalleryTests`; the on-device card with `x^(1/3)` raised is in the `c1-54` screenshot).

Things seen and not fixed: in the `la-12` screenshot the tutor's callout text runs past the right edge of the screen ("Check the bott...")
because the circled line is wide; the marks overlay does not keep a callout inside the screen. A matrix drawn with rows far apart can still
split into two lines (11 of 19 matrix pages agree offline). Two fraction lines nested inside a fraction (`ca12-12`) can still split.
Cramped and wobbly pages still disagree sometimes (offline: 478 of 514 at 0.4 of normal spacing, 432 of 514 with twice the wobble too).
Runs 15 onward used `--silent` (voice path runs, volume 0, logged as `voice_muted_for_test`); the first 14 of the 38 were audible.

## Licence

The single-stroke font is the Hershey set (JSON from scruss/python-hershey). Its terms allow any use, commercial included, if the
acknowledgement ships with the data and the NTIS format is not used; see `tools/handwriting/HERSHEY-LICENSE.txt`.
