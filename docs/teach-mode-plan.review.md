VERDICT: CUT

[REPEAT] Revision 2 fixes the main design objections. The remaining issues can be resolved during implementation and the first real run; they do not justify another planning round.

**1. Unbacked claims**

- [FIX-IN-BUILD] **The line grouper does not identify finished mathematical lines.** It returns geometry, stroke IDs, timestamps and side-calculation status, not completion. Define a conservative attempt rule and exercise blank, partial and erased work. Do not build handwriting recognition just for this flag. Evidence: [LineGrouping.swift:12](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/LineGrouping.swift:12), [LineGrouping.swift:125](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/LineGrouping.swift:125).
- [REPEAT] **Generated-reference reliability and ten-second delivery remain unmeasured targets.** Revision 2 schedules relevant checks; it does not yet establish the results. The existing evaluation explicitly excludes real handwritten mistakes and ask accuracy. Evidence: [no-reference-eval.md:83](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/evals/2026-11-28-no-reference-eval.md:83).
- [REPEAT] **The cost totals no longer describe this design.** The table prices one combined checker call; Revision 2 requires two calls for each of the example and practice. Its “worst case” also uses the deleted fallback. Recalculate from actual usage, including reasoning tokens. Evidence: [teach-mode-plan.md:190](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:190), [pricing.ts:41](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/pricing.ts:41).
- [REPEAT] **Deployment, current allowances and device signing remain unverified.** The refresh step is appropriate. Reusing own-problem’s build path does not settle signing: that document still specifies a laptop build. Evidence: [own-problem-plan.md:56](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/own-problem-plan.md:56).

**2. The smallest version**

- [REPEAT] Keep concept entry, one persistent lesson panel, eight-turn follow-ups, one generated practice problem, the two-call check and sealed reference. Reuse the existing watched page and renderer. These directly cover acceptance without storage, runtime Python or another tutoring engine. The existing client already derives display parts from plain text when parts are absent. Evidence: [Models.swift:56](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/Models.swift:56).
- [REPEAT] Prove one complete real-model flow before expanding the sample or comparing models, per R38. Include reference rejection and answer withholding in that flow.

**3. Delete list**

- [NIT] Delete superseded retry, unchecked fallback, trimming, ratings and threshold clauses, including their tests. Revision 2 explicitly overrides them, so their presence is document cleanup, not a new blocker. Evidence: [teach-mode-plan.md:7](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:7), [teach-mode-plan.md:219](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:219).
- [REPEAT] Remove the inherited laptop build step. “Reuse whatever own-problem settles” must not silently preserve the same standing-rule conflict.
- [FIX-IN-BUILD] Remove the paid-account dependency for checking Release logging. CI can build and exercise a Release simulator configuration; device signing is a separate issue. Current CI explicitly selects Debug. Evidence: [ios.yml:65](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/.github/workflows/ios.yml:65).

**4. Untestable steps**

- [REPEAT] Rendering the generated reference’s own steps as the “correct” page tests consistency, not independent correctness. Verify the generated statement and solution before assigning fixture labels, then retain the real iPad correct-work and planted-slip checks. The fixture renderer itself documents its handwriting limits. Evidence: [teach-mode-plan.md:17](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:17), [make_course_fixtures.py:27](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/make_course_fixtures.py:27).
- [REPEAT] A prompt instruction plus two normalization examples cannot prove “never reveals.” Exercise the actual spoken output on both account types, including equivalent answer forms.

**5. Traps**

- [REPEAT] **Live bypasses the proposed response guard.** Live can answer without delegation; a blank page skips consult entirely. Sending `attempted` to ask, consult and followup therefore does not cover every spoken answer. Carry the pre-attempt behavior through the live route and test it. This remains an answer-hiding issue, not an objection to approved live use. Evidence: [policy.ts:188](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/policy.ts:188), [TutorSession.swift:833](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:833).
- [FIX-IN-BUILD] **An unchecked example can flash before rejection.** Explain returns the example before its check finishes. Keep its contents hidden while pending, not merely after rejection, and exercise a rejected example through the real UI. Evidence: [teach-mode-plan.md:116](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:116), [teach-mode-plan.md:160](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/teach-mode-plan.md:160).

**6. Needs Edward**

- [REPEAT] None for these corrections, per R26. An actual new account purchase or credential requirement would be a separate escalation.

ANOTHER ROUND: NO