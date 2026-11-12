VERDICT: CUT

Keep the native app and server. Cut content breadth and duplicate services. The main correction is measurement: the existing harness cannot substantiate “catching the first wrong step at the right moment” as written. This follows R10: prove the hardest behavior first.

1. **Unbacked claims**

   Owning strokes does not establish meaningful line boundaries. Vertical overlap is an untested grouping rule, especially for fractions, crossed-out work and side calculations ([docs/plan.md:20](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:20), [docs/plan.md:54](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:54)). Check actual Pencil drawings before claiming reliable line targeting.

   The harness counts any interruption inside the catch window as a catch. It never compares the reported mistake with the expected mistake, and its delay excludes model response time ([tt.py:307](/Users/edwardtran/side-projects/smart-math-bc/tutor-timing-test/tt.py:307)). The saved run reports zero delay, but that decision took 7.4 seconds; it contains no clean or self-correction cases ([decisions.jsonl:4](/Users/edwardtran/side-projects/smart-math-bc/tutor-timing-test/runs/synth-haiku-dryrun/haiku/decisions.jsonl:4), [score.md:7](/Users/edwardtran/side-projects/smart-math-bc/tutor-timing-test/runs/synth-haiku-dryrun/score.md:7)). Check mistake identity and elapsed time through visible feedback.

   Eight unit folders exist, but their contents are not independent LaTeX questions. Statistics questions 11–15 share a table outside their numbered blocks ([extra-practice.md:85](/Users/edwardtran/side-projects/smart-math-bc/tutoring/curriculum/bc-math-9/units/08-statistics/practice/extra-practice.md:85)). Check retained context and prompt-to-solution pairing, not merely conversion counts.

   The device/OS numbers, Chiron’s memory diagnosis, pointing research, seven-day signing term and disk/download figures lack supporting repo receipts ([docs/plan.md:16](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:16), [docs/plan.md:119](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:119)). Those need device/crash evidence, the cited paper, current signing documentation and machine measurements. Likewise, account access, missing-key status and one-command installation remain unverified. I did not inspect secrets. Treat 2.5 seconds and 45 seconds as starting defaults, not measured settings.

2. **The smallest version**

   Use a small, checked selection of equation problems, including a fraction, with their existing worked solutions. Build the complete loop: Pencil input, automatic check plus manual check, marked line, written hint, device speech and hold-to-talk. Keep one server path for watching and one for questions, token protection, bounded diagnostic logs and cloud CI.

   This preserves the stated student experience while avoiding a curriculum-import project. Suitable starting questions already exist ([extra-practice.md:15](/Users/edwardtran/side-projects/smart-math-bc/tutoring/curriculum/bc-math-9/units/03-algebra/practice/extra-practice.md:15)). Without credentials, report the overnight result as a tested scripted prototype, as the plan already acknowledges.

3. **Delete list**

   Remove the eight-unit importer and unit navigation from the first build. Curated questions are enough to exercise the experience.

   Remove server TTS, `/api/speak` and its fallback branch. Use the already-proposed device synthesizer directly ([docs/plan.md:66](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:66)).

   Remove the runtime KaTeX/WebView requirement for this fixed selection; bundled rendered prompts can preserve fractions.

   Merge the two handoff documents. Drop the blanket image-input requirement for all four model roles; transcription and speech need their own capability checks ([docs/plan.md:87](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:87)).

4. **Untestable steps**

   Scripted screenshots prove app wiring, not tutoring judgment. Keep them, but validate judgment separately against labelled wrong, clean, unfinished and self-corrected work. Claude results do not validate the eventual OpenAI deployment.

   A decision log alone cannot establish missed mistakes or false alarms: it needs the corresponding work and independently labelled truth ([docs/plan.md:70](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:70)). A screen recording paired with the log is sufficient initially.

   Define scripted mode’s exception to missing-key 503 responses. Verify real Pencil input and memory behavior on the physical device; simulator screenshots cannot settle those.

5. **Traps**

   These are design risks, not reproduced defects:

   - Vertical grouping merges separate steps or splits fractions.
   - A late response circles corrected work or another problem. The contract lacks a drawing revision and explicit stale-response handling ([docs/plan.md:101](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:101)).
   - Snapshot encoding and growing history consume memory and increase requests. “Downscaled” supplies no concrete image, history or concurrency bound ([docs/plan.md:59](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/plan.md:59)).

6. **Needs Edward**

   Only unavailable credentials/account authentication: OpenAI access and Apple signing. No new architecture or vendor decision is needed, per R26.

Read-only review; nothing changed.