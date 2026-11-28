VERDICT: CUT

1. **Unbacked claims**

   - [REPEAT] The session quotations, four repetitions, revision 45 and 14–16-second delay remain unverified in this repo. The cited evaluation covers earlier sessions, not `844b4264` ([evaluation:1](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/evals/2026-11-28-real-ipad-sessions.md:1)). Check the named private log; publishing it is unnecessary.
   - [REPEAT] The one-minute build, 58–70% free memory and implied permission appear only in the plan ([plan:61](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/show-me-plan.md:61)). A previous plan’s signing recipe is not a measurement or an exception to the standing build rule.

2. **The smallest version**

   [REPEAT] Keep this revision’s core: one `solve` action, one small panel, the existing practice action, and consult-based voice routing. The resolver already supplies checked practice steps and answers ([teach-ref.ts:40](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/teach-ref.ts:40)); the lesson panel already demonstrates the rendering components ([LessonPanel.swift:78](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Views/LessonPanel.swift:78)). This meets “show this solution, then another problem” without lesson history or another service. The previous protocol premise is fixed.

3. **Delete list**

   - [REPEAT] Delete local compilation from rollout and the claim that silence overrules the laptop rule. A local signing identity establishes where signing happens, not where compilation must happen ([own-problem-plan.md:56](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/docs/own-problem-plan.md:56)). Keep compilation on CI; handle signing/install separately.
   - [FIX-IN-BUILD] Delete the duplicate spoken start instruction on the voice-triggered path. Answering the delegation already sends commentary ([LiveVoice.swift:237](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Live/LiveVoice.swift:237)). Use that single response after the solution is actually shown. Loading, rejection and failure must not announce “the worked solution is on their screen now.”

4. **Untestable steps**

   - [REPEAT] Silent QA and a scripted consult cannot establish that the real voice delegates, receives the complete solution and teaches it correctly. Silent mode explicitly skips live ([TutorSession.swift:596](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:596)). Keep voice acceptance pending until an actual session records speech → consult → displayed solution → spoken walkthrough. Edward’s session counts when captured; a future session is not a receipt.
   - [REPEAT] Mocked `single_answer: false` proves branching, not mathematical correctness. Run the real generator/checker on the inconsistent system and free-variable system already in the bank, submitted as own problems ([problems.json:68](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/shared/courses/linear-algebra/problems.json:68), [problems.json:87](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/shared/courses/linear-algebra/problems.json:87)).

5. **Traps**

   - [FIX-IN-BUILD] **Blank pages never reach the proposed router.** `TutorSession` returns before calling consult when there is no ink ([TutorSession.swift:847](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:847)). Let blank-page delegations reach classification. Exercise “I have no idea” through `TutorSession` with an empty canvas, not just the `LiveVoice` callback.
   - [FIX-IN-BUILD] **The checker loses information needed by solve.** `checkStatement` returns `not_single` before considering a wrong step and does not expose the underlying flags ([teach.ts:148](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/server/lib/teach.ts:148)). Implement the proposed acceptance rule inside that check or preserve its flags. Never accept every `not_single`; test multiple answers combined with a wrong step.
   - [FIX-IN-BUILD] **Server-first deployment leaves older apps with an empty answer.** Their response decoder has no `show_me` field ([WireTypes.swift:176](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Core/WireTypes.swift:176)) and forwards `answer_text` directly ([TutorSession.swift:897](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor/ios/PencilTutor/Session/TutorSession.swift:897)). Preserve a useful fallback for those clients. Check the new response against the existing client path.

6. **Needs Edward**

   [REPEAT] None, per R26. These are implementation and verification fixes, not a product or vendor fork. Review only; nothing changed.

ANOTHER ROUND: NO