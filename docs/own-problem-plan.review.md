VERDICT: CUT

[NIT] Reviewed `fd5d816`. No files changed or tests run. The revised design is small enough; the remaining corrections belong in the build.

1. **Unbacked claims**

- **REPEAT:** The session numbers now have a source summary, but independent verification remains unavailable: it explicitly keeps raw logs outside the repo, and calls the false alarm a lead because its picture was not retained. The 13 correct pictures, deployed hash, current device connection and usable signing identity remain unverified here. Check the original records and device/deployment receipts. [Session evidence:3](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/evals/2026-11-28-real-ipad-sessions.md:3), [session evidence:17](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/evals/2026-11-28-real-ipad-sessions.md:17).
- **NIT:** “Evidence (committed)” is incorrect: git reports the evidence document untracked. The 31-commit distance checks out. The fixture manifest contains 42 correct and 42 wrong pages; both candidates across 97 pages means 194 looks. “Under $1” is an estimate, since the price table requires token counts. Use the runner’s existing budget control. [pricing.ts:43](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/pricing.ts:43), [run-eval.ts:240](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/run-eval.ts:240).
- **FIX-IN-BUILD:** A watch-only result does not establish no-reference ask/consult accuracy. Exercise those through actual spoken questions before claiming the selected tier works across all three paths. Consult uses a separate policy and the ask configuration. [consult.ts:68](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/consult.ts:68), [policy.ts:200](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/policy.ts:200).

2. **The smallest version**

- **REPEAT:** Keep the typed sheet, existing canvas, one own-problem resolver, four model-request fields, heartbeat validation, no-reference prompts, both empty-answer guards and page-local dismissal with voice cancellation. That meets A without storage or handwritten-question capture. Existing navigation already carries a complete `Problem`. [ProblemListView.swift:23](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Views/ProblemListView.swift:23).
- **FIX-IN-BUILD:** Implement the resolver and guards before running step 0 through the real handler; today it rejects own IDs, and the empty answer downgrades every interrupt. [watch.ts:45](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/watch.ts:45), [decision.ts:39](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/decision.ts:39).

3. **Delete list**

- **REPEAT:** Delete the local `xcodebuild` exception. Your standing instruction prohibits laptop builds. Compile the device target in cloud compute; investigate using the existing identity for local signing/install only. Current CI produces a simulator build. [ios.yml:65](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/.github/workflows/ios.yml:65).
- **FIX-IN-BUILD:** Delete any new scripted own-watch branch: both implementations already wait for every ID except `u3-04`. [decision.ts:55](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/decision.ts:55), [TutorClient.swift:198](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Net/TutorClient.swift:198).
- **FIX-IN-BUILD:** Remove “both exceed 2/13” as sufficient shipping logic. An always-waiting or failing candidate can win on false alarms. Inspect completed calls, failures and caught mistakes together; the scorer already exposes them. [score.ts:101](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/score.ts:101).

4. **Untestable steps**

- **REPEAT:** “Never repeat” cannot be proved by prompt text or clearing `held`. On the iPad, dismiss during queued speech, active speech and a pending consult; retain audio/session receipts. Late consult answers currently go directly to Live. [TutorSession.swift:818](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:818).
- **REPEAT:** The row-opening UI test does not verify drawing around the new button. Exercise tapping, drawing, scrolling and zooming beside it, including near the bottom edge; placement currently assumes a 64-point callout. [MarksOverlay.swift:43](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Views/MarksOverlay.swift:43).

5. **Traps**

- **FIX-IN-BUILD:** `inkSignature` contains rounded stroke bounds, not stroke identity. Rewriting need not change it; automatic page translation does. Preserve disputes through reanchoring and invalidate actual edits. [TutorSession.swift:17](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:17), [TutorSession.swift:260](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:260).
- **REPEAT:** Clearing a held hint does not retract commentary already sent or invalidate an in-flight consultation. Tie dismissal to the associated hint and pending work, then verify actual playback. [LiveVoice.swift:189](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Live/LiveVoice.swift:189).
- **FIX-IN-BUILD:** The eval overrides only unsuffixed model settings. If own problems resolve as advanced, both named candidates could use the advanced default. Verify the actual model used for each candidate. [run-eval.ts:61](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/eval/run-eval.ts:61), [config.ts:114](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/config.ts:114).

6. **Needs Edward**

- **REPEAT:** None identified, per R26. Escalate only if the signing investigation establishes missing account access or credentials.

ANOTHER ROUND: NO