VERDICT: REDO

[REPEAT] The structure is now small enough, but the central “at most US$50” promise still lacks bounded call costs. This is the unresolved round-1 issue, not a new blocker requiring another review round. Read-only review; no tests or production probes run.

**1. Unbacked claims**

- [REPEAT] **US$0.01 is not established as a maximum.** Text calls have no output-token cap and allow retries; models remain configurable. The $0.009 example is valid arithmetic, but not a bound. Check maximum accepted inputs, output/reasoning limits and every provider attempt against the reservation ([models.ts:109](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/models.ts:109), [config.ts:120](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/config.ts:120)).
- [REPEAT] **The audio bounds remain unsupported.** Three synthetic recordings cannot prove “never under-counts”; the server accepts audio based on byte size, without enforcing the app’s format or duration. Likewise, 900 characters/minute is no maximum speech duration. Check actual accepted audio and provider billing rules ([ask.ts:46](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/ask.ts:46), [plan:68](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:68)).
- [REPEAT] **`provider_http_*` does not prove “never billed.”** That label includes unknown status codes; the classifier establishes no billing outcome. Retain reservations unless nonbilling is established ([models.ts:51](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/models.ts:51)).
- [NIT] **“`runTranscription` now returns” duration is premature.** It currently returns text only. Implement that change; a fake duration is not provider evidence ([models.ts:181](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/models.ts:181), [helpers.ts:107](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/test/helpers.ts:107)).
- [REPEAT] Student capacity, current ElevenLabs allowance, vendor rates, header handling, hosting-log retention and migration timing remain unverified. Their explicit assumption labels are appropriate. Check workload receipts, account settings, deployed requests and migration timings; do not turn these estimates into promises ([plan:117](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:117)).

**2. The smallest version**

[REPEAT] Keep the origin column, creation endpoint, atomic IP limiter, monthly budget row, reserve/settle wrapper and existing Keychain/allowance flow. Code generation, collision retries and eight-hour defaults already exist ([students-admin.ts:54](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/students-admin.ts:54)).

[REPEAT] Finish the spending invariant inside that wrapper: enforce request/output limits, reserve for all attempts, and refuse paid work whose maximum cost cannot be bounded. Keep uncertain charges reserved. This needs no additional service or accounting platform.

**3. Delete list**

- [REPEAT] Delete the blanket HTTP-error refund and claims that measured averages are worst cases. They undermine the reserve design ([plan:23](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:23)).
- [FIX-IN-BUILD] Delete “compiled here, not run.” Use the existing cloud workflow before merge; it already runs unit and UI tests, and explicitly requires a green run on that commit ([ios.yml:14](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/.github/workflows/ios.yml:14)).
- [NIT] Delete the unconditional “deletes it after 2 days” wording. Cleanup happens only on successful creation, potentially much later when the ceiling closes creation. Describe that behavior without adding a scheduler ([plan:39](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:39)).

**4. Untestable steps**

- [FIX-IN-BUILD] Varying only `X-Forwarded-For` cannot validate the higher-priority headers. Exercise each trusted header on the deployed endpoint, plus a genuinely different network ([plan:58](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:58)).
- [REPEAT] Keep real-database contention and deployed-app checks. Extend the device receipt beyond creation/relaunch to budget refusal, device voice and memory withdrawal. Scripted tests cannot establish those integrations ([plan:101](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:101)).

**5. Traps**

- [REPEAT] **Under-reserved calls:** a failed settlement is conservative only when the reserve covers the cost. Otherwise it silently undercounts ([plan:64](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/docs/free-launch-plan.md:64)).
- [FIX-IN-BUILD] **Ambiguous insert failures:** a database timeout does not prove insertion rolled back. Releasing the slot could permit extra codes. Release only after a known failed insert, or make insertion and slot consumption atomic ([db.ts:50](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/db.ts:50)).
- [FIX-IN-BUILD] **Month-boundary settlement:** settle against the reserved month, not a freshly calculated month. Include an in-flight call spanning midnight; the gate already captures the month ([gate.ts:103](/Users/edwardtran/side-projects/smart-math-bc/pencil-tutor-free-launch/server/lib/gate.ts:103)).

**6. Needs Edward**

[REPEAT] None for these engineering fixes, per R26. Only accepting an estimated threshold instead of the promised hard ceiling needs a money decision; Apple enrollment/payment remains separate if unavailable.

ANOTHER ROUND: NO