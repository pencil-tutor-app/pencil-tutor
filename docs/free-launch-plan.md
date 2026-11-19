# Free launch: "Start free" codes, an abuse guard and a monthly spending ceiling

Owner decision 2026-11-19: the app is free on the App Store. Branch `free-launch`. Hand-made codes (`server/scripts/codes create`)
keep working exactly as today; this adds a second way to get a code. Review history is at the end ("Changes after plan review").

## What

1. **Start free.** A button on the code screen asks the server for a new code (8 hours a month, live voice off, the same meter,
   caps, notices and Keychain storage as a typed code). The student is signed in at once. No name, email or sign-up.
2. **Abuse guard (phase 1, no Apple account).** At most 3 free codes per network address per rolling 24 hours (`FREE_CODE_PER_IP_PER_DAY`).
   Only an HMAC of the address is stored (key: `FREE_CODE_IP_SALT`, unset means creation is refused); the raw address is never stored or
   logged. IPv6 is grouped by /64. **App Attest is phase 2** (needs the paid Apple account): a marked comment at the exact call site plus
   the note at the end of this file. No code, no env flag, no log field.
3. **Spending ceiling.** All free codes together may cost at most US$50 per Vancouver calendar month (`FREE_MONTHLY_CEILING_USD`;
   `0` closes free tutoring). The running total is one stored number, `free_spend_months.spent_micros`. It is an **estimate** (the
   price tables in `pricing.ts` plus the audio rates below), not the provider's invoice.
   - **Reserve before, settle after.** Before every paid call for a free code the server atomically adds a worst-case amount
     (`reserve`) to the total, and refuses the call if that would pass the ceiling. After the call it replaces the reserve with the
     estimated real cost (`settle`, which may be negative). So the sum of the reserves of calls in flight can never push the total past the
     ceiling; only an actual cost above its own reserve can (it is then added in full). This replaced "check, call, then add", which did not bound
     parallel calls (review point 1).
   - **Anything uncertain keeps the reserve.** No usage in the reply, a provider error, a timeout: the call stays counted at its
     reserve and is logged `cost_basis: reserve_kept` with the reason. Nothing is refunded unless the call returned usage (the classifier
     cannot prove an error was not billed). An outage therefore over-counts by one reserve per failed call; `codes free-spend --set` corrects the total.
   - **The reserve is a bound, built from enforced limits** (`reserveUsd` in `lib/free.ts`): the image is at most 1024 px and 400 KB
     (`lib/image.ts`), the prompt text is capped by schema (200 lines, 10 history entries, 800-character question, 8 recent turns),
     the output is capped by `maxOutputTokens` (default 3,000, env `FREE_MAX_OUTPUT_TOKENS`, sent for free codes only, reasoning
     included), and the SDK retries once, so a text call reserves `2 x (25,000 input tokens x the model's input rate + 3,000 x its output rate)`
     from `pricing.ts`: US$0.008 on gpt-6-luna, US$0.16 on gpt-6.1-sol. 25,000 input tokens is 13 times the 1,841 measured on a look;
     it is the one assumed number, and an actual cost above its reserve is added in full at settle. **A model with no price cannot be bounded, so a
     free code's call to it is refused** (503 `bad_config`, reason `free_model_unpriced`).
   - At or over the ceiling: no new free codes, and every endpoint that costs money (watch, ask, consult, speak, live-session, and
     heartbeat) answers 403 `free_tutoring_full` for a free code, **including the allowance notices** (the app then speaks them on the
     device voice). `GET /api/me` and `/api/memory` stay open so the banner can clear on the 1st and a family can still withdraw or erase memory.
   Hand-made codes are never checked.
4. **Logging.** Every decision logs a reason label with ids, counts and hashes only (never a code, address, secret or content), on the
   success branch too. The creation line carries the code's log id and never the address hash; the refusal line carries the address hash
   and no code.

## Schema (migration `005_free_codes.sql`, additive only)

| change | why |
|---|---|
| `students.origin text not null default 'admin'` with a named check `('admin','free')` | marks free codes; every existing row becomes `admin`; a constant default is metadata-only in Postgres 11+ (assumed for Neon, not measured) |
| `free_spend_months (month date pk, spent_micros bigint check >= 0, eleven_chars bigint, calls bigint, updated_at)` | the running total, one row a month, in millionths of a dollar. `eleven_chars` is information only (see assumptions) |
| `free_code_ip_limits (ip_hash text pk, stamps timestamptz[], updated_at)` + index on `updated_at` | one row per address hash holding at most `limit` timestamps; rows not touched for 2 days are deleted on each successful creation |

No student id is stored next to an address hash. Two things can still re-link them: the creation time is in both `students.created_at` and
`stamps`, so the policy treats the hash as personal information; and the logs never put the two on one line. Rows not touched for 2 days are
deleted by the next successful creation and by `codes free-spend`, with no scheduler; while creation is closed or idle they wait for one of those.
No data is dropped, rewritten or backfilled. `students.origin` is read by every request, so **run `codes migrate` before deploying
the server**.

## Server

- `POST /api/free-code` (no auth; `server/api/free-code.ts`, `server/lib/free-code.ts`). Order: method (405), salt set and 16+ chars
  (else 503 `free_codes_unavailable`, reason `ip_salt_not_set`), ceiling (403 `free_tutoring_full`; checked before the slot so a full
  month burns nobody's slot), address present (else 400 `no_client_ip`), `APP_ATTEST_SEAM` comment, address slot (429 `rate_limited` with
  `Retry-After`), insert the code (`origin 'free'`, 28,800 s, live off, up to 8 tries on a collision), purge old address rows, 200 `{code, cap_minutes}`.
- **Slot lifecycle.** The slot is claimed before the insert (so a flood cannot create rows). The slot is released (`array_remove`) only after
  a **known** failed insert, meaning the database answered with an SQLSTATE error, which rolled the statement back. After a timeout or a network
  error the insert may have happened, so the slot is kept and `free_code_insert_outcome_unknown` is logged. If the reply is lost on the way to
  the iPad, the slot stays used: the student can tap again and loses one of three. All three cases are tested or documented.
- The slot is one statement: `insert ... on conflict (ip_hash) do update set stamps = (stamps newer than 24 h) || now where (count of
  those) < limit returning ...`. The row lock is what makes it race-free. A refused request writes nothing, so hammering does not
  extend a lock-out.
- `server/lib/free.ts`: env parsing, address read (`x-vercel-forwarded-for`, `x-real-ip`, first `x-forwarded-for`; Vercel's documentation
  says it overwrites these so a client cannot choose its own; to be confirmed after deploy), HMAC, ceiling check, the reserve/settle wrapper.
- Gate: `lookup` also returns `origin` and, for a free code, this month's `spent_micros` (one extra primary-key join in the query that
  already runs). Gate option `skipFreeCeiling` is set only by `me` and `memory`. A free code never gets live voice, whatever `plan_live`
  says (it is billed by the minute, which the server cannot see, so it could not count toward the ceiling).
- `GET /api/me` adds `free: {full: bool}` for free codes only.
- **Cost counted** (free codes only; a failed settle logs `free_spend_not_recorded` and leaves the reserve in place, which is the full bound,
  so it over-counts rather than under-counts). Reserve and settle both use the month the gate captured, so a call that spans midnight
  settles against the month it reserved in.
  - watch, ask-model and consult: the text-call reserve above; settle `est_cost_usd`. Reword (`lib/record/reword.ts`) is the same with one attempt.
  - speech-to-text: US$0.0045 a minute (gpt-transcribe, OpenAI model page). A free code's audio is capped at 300 KB (the app's
    30-second limit measured at 26 to 114 KB on this Mac with its recorder settings: 882 B/s silence, 1,851 voice-like tone, 3,791 noise;
    synthetic audio, not real speech). Reserve `bytes / 800 B/s` at the rate (at most US$0.028 an attempt, US$0.056 for two); settle the provider's `durationInSeconds`
    when it returns one (`runTranscription` is changed to pass it through; unverified that gpt-transcribe sends it), else keep the reserve.
    A deliberately low-bitrate file could still cost more than its reserve; the settle adds any reported excess.
  - OpenAI speech fallback: US$0.015 a minute (gpt-4o-mini-tts, OpenAI's own estimate). The text is at most 600 characters; reserve it
    at 600 characters a minute (slow speech, at most US$0.015 per attempt, two attempts); settle from the PCM returned (48,000 B/s).
  - **ElevenLabs counts as 0 dollars** (flat plan already paid); its characters go into `eleven_chars`.
- `codes list` adds an origin column and one line `free spend this month: $X of $Y`; `codes list --free` lists free codes only; `codes
  free-spend [--set USD]` shows or corrects this month's total and purges stale address rows; `codes live` refuses a free code.
- `GET /api/health` reports `free_codes: {creation, reason, ceiling_usd, per_ip_per_day}`. Configuration only: it does not touch the
  database, so it proves neither remaining budget nor a working creation.

## App (SwiftUI)

`CodeEntryView`: a "Start free" button under Continue (`startFreeButton`). `StudentAccount.startFree()` calls the new `createFreeCode`
closure, validates the shape, saves to the Keychain through the same `StudentCodeStoring`, becomes `.ready`, then runs the usual `refresh`.
New `TutorError` cases `freeTutoringFull` (403) and `freeCodeLimit` (429) with kind wording; `StudentAccount.Block` gets `freeTutoringFull`,
cleared when `me` says `free.full == false`. `HTTPTutorClient.createFreeCode()` sends no bearer. The scripted client gains
`createFreeCode()` and `--scripted-needs-code` (start on the code screen instead of signed in).

## Tests (what each one does and does not prove)

- `server/test/free.test.ts`, in memory, runs on the laptop: creation and its reply; per-IP limit (3 then 429, a refusal writes nothing, another
  address still works, IPv6 /64 grouping, rolling 24 h); insert failure releases the slot; salt unset; ceiling closes creation, closes
  every paid endpoint for a free code including notices, leaves `me` and `memory` open; hand-made codes unaffected at the ceiling; reserve
  and settle for watch, ask, consult, speech fallback, unknown usage, provider errors and an unpriced model; the reserve refusing parallel
  calls that would pass the ceiling; month rollover (Nov 30 and Dec 1, Vancouver, including a call that spans midnight); logs
  carry no code and no address, and no line holds both a code id and an address hash.
- `server/test/free.pglite.test.ts`, the real SQL on PGlite (`PT_PGLITE=1`; CI sets `CI=true`): migration 005 applies twice, the limiter's
  statement, reserve, settle, lookup join and rollover give the same answers as the in-memory store. PGlite runs one connection, so it
  **proves SQL correctness, not concurrency**.
- `server/test/db.integration.test.ts` gains contention cases (many simultaneous slot claims and reserves, real requests to the real
  database); they are skipped unless `PT_DB_INTEGRATION=1`, **written here but not run** (that needs the production database address,
  which this task may not use). Run after `codes migrate`.
- iOS: one UI test, `testStartFreeSignsInWithoutTypingACode`, on the scripted client, run once on one iPad simulator: it proves the button,
  the sign-in transition and the list. It does not prove HTTP, Keychain persistence or the deployed server. Unit tests for `startFree`, the
  new errors and the reply decoding are written but not run on this laptop (task rule); the manual iOS workflow must be green on the merge commit.
- Rollout checks that no test here can do are listed below.

## Rollout

1. Merge. 2. `server/scripts/codes migrate` (applies 005). 3. In Vercel production set `FREE_CODE_IP_SALT` (random, 32+ characters; never
printed) and, if wanted, `FREE_MONTHLY_CEILING_USD`. 4. Deploy the server: hand-made codes are unchanged; without the salt the endpoint
answers 503. 5. Check `/api/health`. 6. Make free codes with curl, four times each with a made-up value in `X-Forwarded-For`, then `X-Real-IP`, then `X-Vercel-Forwarded-For`
(the 4th must answer 429 each time, so none of the three can be spoofed), then once from a different network (it must succeed); delete the
test codes with `codes delete`. 7. Run the real-database contention tests. 8. Run the iOS workflow (manual). 9. On a device against a preview
deployment: tap Start free, quit, relaunch (the same code persists); with `FREE_MONTHLY_CEILING_USD=0` on that preview, check the kind
banner, the device-voice notice and that Settings, "What the tutor remembers", still withdraws. Kill switch: `FREE_MONTHLY_CEILING_USD=0`.

## Assumed, not measured

- A fully used free month costs about US$0.5 to 1 (2,880 looks of about US$0.00016 plus questions), so US$50 is roughly 50 to 100 busy
  students a month. The looks-per-hour figure is a guess.
- The estimate can be wrong in either direction: unverified that `gpt-transcribe` reports a duration; prices come from the vendors' pages
  read 2026-11-19 and may change; the 25,000 input-token figure is an assumed bound, not a provider limit. **The only hard cap is the
  provider's own spend limit on the OpenAI project** (Edward's dashboard); this ceiling is the server's estimate with reserved headroom.
- Vercel overwrites client-supplied address headers: from its documentation, not observed on a deployment.
- Whether Vercel's own request records keep addresses: not checked; the policy says "to confirm".
- Neon timing and migration speed: not measured (no production access); SQL is checked on PGlite only.
- **ElevenLabs is a shared pool of 157,028 characters a month (documented in `how-to-run.md`, not re-verified), not a dollar cost.** Free users
  can drain it long before US$50 is spent, after which paying students' voice falls back to OpenAI. Counted as 0 on the owner's instruction;
  `eleven_chars` gives the numbers. Edward's call.
- Schools and families share one address: 3 codes per address a day can lock a classroom out. Kind message; the limit is an env var.
- Free students see "Ask Edward for more time" when their 8 hours run out; wording unchanged, Edward's call.

## Phase 2: App Attest (not built)

`APP_ATTEST_SEAM` in `server/lib/free-code.ts` marks where it goes: after the ceiling check, before the address slot. The app attests a key
with Apple's DeviceCheck service against a server challenge, the server verifies the attestation once and stores the key id and counter, and every
free-code request carries an assertion. It needs the paid Apple Developer account and a real device. Nothing of this exists yet.

## Changes after plan review

Round 1 (Astra, REDO, `free-launch-plan.review-round1.md`): the ceiling was "check, call, then add", so parallel calls could pass it, and
unknown usage and billed failures went uncounted. Changed: reserve and settle; paid allowance notices now refuse at the ceiling (device voice
instead); `memory` and `me` skip the ceiling; the slot is released after a failed insert; the address hash never shares a log line with a
code; the speech-to-text rate was measured; PGlite's claim is limited to SQL correctness and real-database contention tests were added (unrun).
Deleted: the App Attest function, call, log field and env flag; the "active/minutes" admin summary; the index-use assertion.

Round 2 (Astra, REDO again, `free-launch-plan.review.md`, which also said no further round): the reserve of US$0.01 was not a bound, `provider_http_*`
was assumed unbilled, the audio bound rested on three synthetic clips, a database timeout is not a failed insert, and settling used a fresh
month. Changed: the reserve is built from enforced limits (output-token cap, image and text limits, retries, a 300 KB audio cap, 600
speech characters) and the model's own price, and an unpriced model is refused; nothing is refunded without usage; the slot is released only
after a known failure; reserve and settle share the gate's month; the rollout checks every address header and a second network and extends the
device receipt to the refusal, the device-voice notice and memory withdrawal; the 2-day purge wording no longer promises a timer. Not changed,
with the reason: the ceiling stays an estimate (the provider's own spend limit is the only hard cap, now stated), and the iOS unit tests
stay unrun here because this task forbids triggering the iOS workflow.
