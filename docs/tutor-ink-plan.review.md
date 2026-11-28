VERDICT: CUT

1. Unbacked claims

- **REPEAT:** The separate checker still does not establish that the proposed edit fixes the selected ink. Checking two transcribed lines can approve correct algebra attached to the wrong tags. Verify the tagged snapshot, original line and exact replacement together. Also, N−1 need not supply the necessary context: an existing fixture checks an exponent of `n` after a separate calculation involving `m` ([make_course_fixtures.py:148](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/make_course_fixtures.py:148)). Include the problem and relevant earlier work.
- **FIX-IN-BUILD:** “Plain characters” does not guarantee the font can draw them. The synthesizer throws for unmapped characters ([ink_synth.py:97](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/tools/handwriting/ink_synth.py:97)); stored solutions already contain `¬`, `∧` and `∨` ([problems.json:14](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/shared/courses/discrete-math/problems.json:14)). The inventory must check character coverage as well as constructs.
- **REPEAT:** Horizontal gaps still have no demonstrated term accuracy. Existing line grouping explicitly describes itself as a hypothesis ([LineGrouping.swift:35](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/LineGrouping.swift:35)). Check actual tagged handwriting, especially fractions and matrices. The 2–4-second duration is a tuning target, not established performance.

2. The smallest version

- **REPEAT:** The revised scope is appropriately small: reuse the fetched solution, glyphs and stroke conversion; use one passive drawing layer; advance explicitly; correct only a requested flagged line. Existing solution reuse is already implemented ([ShowMeSession.swift:76](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/ShowMeSession.swift:76)), and stroke conversion exists ([InkReplay.swift:115](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Debug/InkReplay.swift:115)). This covers writing, pointing and correction without automatic watch tagging or speech-end machinery. Keep the second check; fix what it checks.

3. Delete list

- **FIX-IN-BUILD:** Delete the arbitrary eight-line context cutoff. Generated solutions permit twelve steps ([teach-policy.ts:23](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/teach-policy.ts:23)). Retain stable numbering and context for the visible tutor work; otherwise “your second line” becomes unreliable.
- **FIX-IN-BUILD:** Delete the requirement that fallback text occupy one line. Steps can contain 200 characters ([teach-policy.ts:22](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/teach-policy.ts:22)). Preserve content and wrap legibly.
- **REPEAT:** Delete the assumption that a future Edward session completes the QA obligation. It is a source of future evidence, not a receipt already earned. The existing device report explicitly leaves spoken behavior uncovered ([show-me-device-qa.md:21](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/evals/2026-11-28-show-me-device-qa.md:21)).

4. Untestable steps

- **FIX-IN-BUILD:** `planted` and `wrong_line` identify the mistake, not correct tag boundaries ([manifest.json:79](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/fixtures/courses-messy/manifest.json:79)). Score the actual tagged picture and resulting strike/replacement against an annotated target. A successful handler response alone cannot prove pointing.
- **REPEAT:** Silent QA cannot establish spoken Next, interruption or audible pacing: it disables live voice ([LaunchOptions.swift:83](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/LaunchOptions.swift:83)). Keep silent visual receipts, then record an audible run and actual Pencil mistakes plus correct controls. Until then, label those behaviors unverified.

5. Traps

- **REPEAT:** Revision equality does not protect coordinates across reanchoring. Reanchoring translates drawing and marks, while its drawing callback deliberately skips revision increments ([TutorSession.swift:304](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:304), [419](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:419)). Move pending correction targets and animation coordinates too, or discard them.
- **FIX-IN-BUILD:** A requested older flagged line may be outside the snapshot. Large-page capture follows the newest ink ([PageSnapshot.swift:180](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Drawing/PageSnapshot.swift:180)). Capture the selected target and required context explicitly.
- **FIX-IN-BUILD:** Removing the panel also requires replacing the existing whole-solution voice instruction. It currently pushes every step and requests a walkthrough ([TutorSession.swift:975](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:975)). Otherwise narration can outrun Next.

6. Needs Edward

- **NIT:** None under R26. These are implementation fixes and evidence gaps, not direction calls. Read-only review; no files changed.

ANOTHER ROUND: NO