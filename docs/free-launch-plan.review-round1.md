VERDICT: REDO

The code-creation design is reasonable. The spending design does not establish its central promise: at most US$50. This was a read-only source review; no tests or production probes were run.

1. **Unbacked claims.**

   “A few calls, cents” of overshoot is unsupported. Checking before calls and recording afterward does not bound concurrent spending. Ignoring accounting failures can leave spending permanently uncounted ([plan:47](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:47)).

   The one-cent fallback covers unknown prices, but leaves missing usage unresolved. `reportUsage` explicitly returns `no_usage`; failed reword calls discard usage ([usage.ts:28](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/usage.ts:28), [reword.ts:103](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/record/reword.ts:103)). Check billed failures and missing usage, not just successful responses.

   Transcription currently returns only text, discarding any provider duration. AAC settings specify no bitrate, so “2,000 B/s over-counts” is unproven ([models.ts:181](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/models.ts:181), [AudioRecorder.swift:43](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/ios/PencilTutor/Audio/AudioRecorder.swift:43)). Verify returned metadata, actual recordings and billing rates.

   The $0.00016 look estimate has repo support, but 2,880 looks and 50–100 students remain workload guesses ([server/README.md:185](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/README.md:185)). The 157,028-credit pool is documented, not currently verified ([how-to-run.md:79](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/how-to-run.md:79)).

   Header overwrite guarantees, hosting logs never retaining addresses, address-to-code unlinkability, and migration timing are also unverified. Check deployed header handling, log fields and hosting settings, and the actual migration. Separate database tables alone do not prove unlinkability ([plan:28](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:28)).

2. **The smallest version.**

   Keep the origin column, creation endpoint, atomic IP limit, monthly budget row, existing allowance/Keychain flow, and refusal UI. Code generation and eight-hour defaults already exist ([students-admin.ts:54](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/students-admin.ts:54)).

   For the stated hard ceiling, require bounded call costs and an atomic budget reservation before paid work. Retain the reservation when usage is unknown. This belongs in the existing database, without another service. Otherwise describe this as an estimated spending threshold and obtain approval for that weaker money promise.

3. **Delete list.**

   Remove the always-successful App Attest function, invocation, log field and future enforcement flag. They enforce nothing; a short deferred-work note is enough ([plan:96](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:96)).

   Drop the expanded “active/minutes” admin summary. Origin plus monthly spending is enough for launch; “active” is undefined.

   Drop the mandatory index-use assertion. A tiny monthly table does not need an index scan to be fast. Keep correctness and realistic timing checks.

   Keep health configuration-only. It currently performs no database query, so it cannot certify remaining budget or working creation ([health.ts:8](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/health.ts:8)).

4. **Untestable steps.**

   Twenty promises against PGlite do not prove production concurrency. The existing test explicitly says this ([record.pglite.test.ts:15](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/test/record.pglite.test.ts:15)). Keep PGlite for SQL correctness; use separate real database requests for contention, following the existing integration-test pattern ([db.integration.test.ts:91](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/test/db.integration.test.ts:91)).

   Scripted sign-in does not prove HTTP wiring or Keychain persistence. Run the existing cloud iOS workflow and exercise creation, relaunch and refusal against the deployed server, retaining screenshots/logs. The workflow already runs UI tests ([ios.yml:97](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/.github/workflows/ios.yml:97)).

5. **Traps.**

   **Paid notices bypass the ceiling.** Notice requests still reach ElevenLabs or OpenAI, with no server-side once-only restriction ([speak.ts:55](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/speak.ts:55), [speak.ts:107](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/speak.ts:107)). Use the existing device voice after closure.

   **The blanket gate blocks memory controls.** Withdrawal and erasure deliberately remain available beyond allowance exhaustion. Preserve that behavior ([record/endpoint.ts:10](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/record/endpoint.ts:10)).

   **Creation failures consume scarce slots.** The proposed slot claim precedes insertion. Failed insertion or a lost reply can exhaust a family’s allowance without delivering three usable codes ([plan:35](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:35)). Define and test this failure behavior.

6. **Needs Edward.**

   None for routine engineering, per R26. Only accepting a weaker spending promise, or Apple enrollment/payment if still unavailable. Unsigned CI builds do not establish App Store readiness ([ios.yml:68](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/.github/workflows/ios.yml:68)).