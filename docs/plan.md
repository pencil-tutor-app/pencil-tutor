# Pencil Tutor: version one build plan

Written 2026-11-13. Owner: Edward. Personal side project (not BLI work).

## What it is

A native iPad app. A student picks a BC Math 9 problem, works it by hand with an
Apple Pencil, and an AI tutor watches the page. When a finished line contains a
clear, consequential mistake, the tutor circles that line on the page, writes a
short hint beside it, and says the hint out loud. The student can also hold a
button and ask a question by voice. Version one is practice only: no lectures,
no note-taking, no accounts.

Why this shape (decided with Edward on 2026-11-12/13):
- iPadOS cannot draw over other apps, so the tutor owns the page.
- The test device is Edward's 9th-generation iPad (iPad12,1, 3 GB, iPadOS
  26.6.1). The nearest competitor (Chiron) is unusable on it; the system kills
  apps for memory there. So the iPad does as little as possible: ink, layout,
  playback. All model work runs on a server.
- Owning the page means we know every stroke and every line's position, so the
  model only has to name a line number, never point at pixels (published
  results show current models are poor at pointing on handwriting).

## Done by morning (acceptance criteria)

1. App builds for iPadOS 26 on GitHub Actions (macOS runner); unit tests pass.
2. A UI test on the iPad simulator, against the server in scripted mode, draws
   strokes for a problem with a planted mistake and one clean problem, and saves
   screenshots as CI artifacts: problem shown, ink drawn, red circle and hint on
   the wrong line, and no interruption on the clean problem.
3. Server deployed to Vercel (team "edward's projects"). `/api/health` reports
   whether the OpenAI key is present. Without a key every model endpoint answers
   503 with the plain reason "OPENAI_API_KEY is not set".
4. A first measurement of the hard part (catching the first wrong step at the
   right moment without false alarms) on a synthetic set, using the existing
   harness in `../tutor-timing-test`, with Claude models via the signed-in CLI.
   Clearly labelled: font-rendered "handwriting", not real.
5. Xcode installed on the Mac (or the exact reason it is not), so the morning
   device install is one command.
6. `docs/how-to-run.md` and `docs/morning.md`: the at-most-three steps Edward
   must do, in order.

Not possible overnight, said up front: the real model inside the app (no OpenAI
key until Edward adds one) and the app on the physical iPad (needs Edward's
Apple ID in Xcode and the iPad plugged in).

## Architecture

### iPad app (SwiftUI + PencilKit, deployment target iPadOS 26.0)
- Problem list grouped by unit; problem screen with the problem card on top and
  a PencilKit canvas below. Pencil-only drawing; finger scrolls (the page is endless downward and has a lasso, amendment 15).
- Problem card renders the LaTeX from the bank (fractions must render). A
  bundled offline KaTeX in a small WKWebView is acceptable.
- Line tracking: strokes are grouped into lines by vertical overlap. Each line
  has an index, a bounding box and the time of its last stroke.
- When to look: after the pen has been idle for 2.5 s (configurable) and the
  page changed since the last look; never within 45 s after an interruption
  (cooldown enforced in the app); plus a "Check my work" button.
- What is sent: a downscaled PNG of the page with faint line numbers in the left
  margin, the line list, the problem id, and the log of this session's earlier
  decisions. The server holds the reference solutions, so they never ship in a
  way the student can read.
- On "interrupt": draw a red ellipse around the named line on an overlay layer
  (not inside the student's drawing, so it cannot be erased by accident and can
  be cleared), write the short hint beside it, and speak the hint.
- Voice out: server text-to-speech; fall back to the on-device synthesizer if
  the server fails, and say so in the log.
- Voice in: hold-to-talk records audio, the server transcribes it and answers
  with the page in view, the answer is spoken.
- On-device session log (JSONL): every look, decision, latency and error. This
  makes Edward's first real session the timing test. Exportable via share sheet.
- Server URL and an app access token come from a build setting file that is not
  committed (a committed example file shows the shape).

### Server (Vercel Functions, TypeScript, no framework)
- `POST /api/watch`: page PNG + lines + problem id + history ->
  `{action: "wait"|"interrupt", line, reason, hint_spoken, hint_written}`.
  Policy: waiting is the default; interrupt only for a clear, consequential
  wrong step on a line that looks finished; an unfinished line or a pause is not
  a reason; hint, never the answer; compare against the reference solution but
  accept any valid method.
- `POST /api/ask`: audio + page PNG + problem id -> transcript + spoken answer
  text.
- `POST /api/speak`: text -> audio.
- `GET /api/health`: version, key present yes/no, models configured.
- Every request needs the app access token (so strangers cannot spend the key).
- Model ids come from env vars (`WATCH_MODEL`, `ASK_MODEL`, `TTS_MODEL`,
  `STT_MODEL`). Defaults must be models verified today, from OpenAI's own docs,
  to accept image input; record the source URL in the docs.
- Scripted mode (`TUTOR_SCRIPTED=1`, test only): deterministic decisions so the
  simulator UI test needs no key and no network spend.
- Logging: request id, endpoint, model, latency, image bytes, action, line,
  reason label. Never images, audio, transcripts or keys.
- Problem bank: a script converts the 8 units of
  `../tutoring/curriculum/bc-math-9/units/*/practice/extra-practice*.md` into
  `problems.json` (id, unit, tier, prompt LaTeX, worked solution, final answer).
  Problems that are not "work it on paper" (explain-in-words, error-hunting
  someone else's work) are excluded and counted in the log.

### Contract (both sides build against this)
`/api/watch` request JSON: `{session_id, problem_id, image_png_base64,
image_width, image_height, lines: [{index, box: {x,y,w,h}, last_stroke_at}],
history: [{at, action, line, hint_written}], client_time}`. Response as above
plus `{request_id, model, latency_ms}`. Errors: `{error, reason}` with HTTP
401 / 422 / 503.

## Build and test location
- Edward's laptop stays green: iOS builds, simulator runs and test suites run
  on GitHub Actions in a new private repo `giaphutran12/pencil-tutor`. Locally
  only light checks (TypeScript build of a single file, the content script).
- The overnight model measurement uses the Claude CLI at most two calls at a
  time.

## Out of scope for version one
Live streaming voice (GPT-Live / realtime; **reversed by amendment 12**), explaining from Edward's concept
notes, accounts, multiple pages per problem, photo import of homework, iPadOS 27
handwriting recognition, analytics, App Store / TestFlight.

## Amendments after plan review (verdict CUT, docs/plan.review.md), these override the sections above

1. Content: no eight-unit importer and no unit navigation. A curated list of
   about 12 equation problems from unit 3 (algebra), including fractions and a
   distributed negative, each paired by hand with its existing worked solution
   and final answer. Check every prompt-to-solution pairing.
2. Problem card: no WebView or KaTeX. Render the fixed prompts natively (a
   small SwiftUI fraction view is enough) or as bundled pre-rendered images.
3. Voice out: device speech synthesizer only. No `/api/speak`, no server TTS.
   **Reversed by amendment 11 below (2026-11-13): the device voice was judged
   unacceptable, server TTS is back.**
4. Server: `/api/watch`, `/api/ask`, `/api/health` only (plus `/api/speak`, see amendment 11). Capability checks per
   role: the watch and ask models must take images; the transcription model
   must take audio. Provider is a setting (OpenAI or Gemini), because both keys
   exist and Gemini topped a handwriting-grading leaderboard.
5. Contract additions: every watch request carries `drawing_revision`; the
   response echoes it. The app discards a response whose revision is older than
   the current drawing unless the named line is unchanged. One request in
   flight at a time. Image: longest side at most 1024 px, PNG or JPEG under
   400 KB. History: last 10 decisions only.
6. Scripted mode: when `TUTOR_SCRIPTED=1` the server answers from a fixed
   script without a key; it is the only exception to the missing-key 503, and it
   is never enabled in production.
7. Line grouping is a hypothesis: unit-test it on fractions (stacked strokes),
   crossed-out work and a side calculation, and log the line count per look.
8. 2.5 s idle and 45 s cooldown are starting defaults, not measured settings.
9. Judgment is measured separately from wiring, against labelled wrong, clean,
   unfinished and self-corrected work, scoring the named line, and delay
   including model latency. Claude results do not validate an OpenAI or Gemini
   deployment; the same synthetic set is re-run against the deployed watch
   endpoint.
10. One handoff doc only: `docs/how-to-run.md`.

### Amendment 11 (2026-11-13, after first real use): amendment 3 is reversed

Edward used the app on the iPad and judged the on-device voice unacceptable
(robotic). So `POST /api/speak` is back, as originally planned: OpenAI
text-to-speech (`gpt-4o-mini-tts`, voice `coral`, mp3) served by our own
server, same bearer token, same scripted-mode and missing-key rules as
`/api/ask`. The iPad plays it with `AVAudioPlayer`, caches identical text in
memory, and falls back to the device synthesizer (best installed English voice)
when the server fails, takes over 4 s, or the text is over 600 characters.
Hold-to-talk still wins: nothing plays while the student is recording. The
server now has four endpoints: watch, ask, speak, health. Contract and settings
are in `server/README.md`.

### Amendment 12 (2026-11-13): the voice moves to GPT-Live-1; amendment 11's voice is now the fallback

**Superseded as the default by amendment 13 (2026-11-14):** GPT-Live is now a premium option, off unless the student's plan has
`live: true`. The base voice is ElevenLabs Eleven v4 Turbo with tap-to-talk. Everything below still describes the live path.

Why: `gpt-4o-mini-tts` is an old model, and OpenAI's deprecations page lists it as deprecated with shutdown on
2027-01-06 (https://developers.openai.com/api/docs/deprecations). The current voice model is GPT-Live-1 (`gpt-live-1`),
a full-duplex voice model: the student now talks to the tutor naturally while a problem is on screen, instead of holding
a button and waiting for a spoken answer. "Live streaming voice (GPT-Live / realtime)" in the out-of-scope list above is
therefore reversed.

What changed:
- The iPad opens a GPT-Live session when a problem opens, over WebRTC (`stasel/WebRTC`). The OpenAI key stays on the
  server: `POST /api/live-session` relays the SDP offer and answer. OpenAI documents no ephemeral secret for Live.
- GPT-Live takes no images. When it must judge the work it delegates; the app captures the page and calls the new
  `POST /api/consult` (same ask model and image handling as `/api/ask`), and returns the report as
  `session.commentary.append`. Watch hints and the "Check my work" verdict are said by the same voice, and the latest page
  check is pushed as `session.thinking.append`.
- Hold-to-talk becomes a mic mute toggle while live. If Live cannot connect or drops, the earlier path (hold to ask,
  `/api/ask`, `/api/speak`, device voice) takes over and the reason is logged. No automatic reconnect.
- Voice `gleam` (this amendment's default; replaced by `meridian` in amendment 14, set with `LIVE_VOICE`), chosen from the documented voice table (North American, feminine,
  recorded rather than generated), not by ear.

Cost: voice is $0.05 per minute of open session (billed per second, $3.00 per hour), plus the normal ask and watch model
rates for each page look. A session that sees no ink and no speech for 5 minutes closes itself (a chosen default). No claim
is made that it is cheaper, faster or better sounding than the old path; latencies and usage seconds are in the session log.

Plan and its review: `docs/live-voice-plan.md`, `docs/live-voice-plan.review.md` (verdict CUT; page summaries, auto
reconnect and hint-timing gates were cut). Server contract: `server/README.md`. Running it: `docs/how-to-run.md`.

### Amendment 13 (2026-11-14): the base plan is tap-to-talk in Edward's own voice, one code per student, 8 hours a month

Edward approved this as the product: **CA$19 a month for 8 hours.** It overrides amendment 12 for the default path. GPT-Live
stays in the code as a **premium option, off by default**.

**What the student gets.** The tutor speaks in one voice for every utterance (answers, hints, check verdicts): ElevenLabs
**Eleven v4 Turbo** (`eleven_v4_turbo`), streamed so the first audio plays before the sentence is finished. The mic button is
tap-to-talk: tap to start, tap again to send (auto-stop at 30 seconds). Until Edward's voice clone exists the voice is the premade
American male voice **Eric** (`cjVigY5qzO86Huf0OWal`, labelled "Smooth, Trustworthy", conversational); the clone is one setting
away (`ELEVENLABS_VOICE_ID`). Fallback order: ElevenLabs, then OpenAI text-to-speech (`gpt-4o-mini-tts`, deprecated 2027-01-06), then
the device voice. Each fallback is logged with its reason. Both servers' audio arrives in one wire format (16-bit little-endian
mono PCM, 24 kHz), which the iPad plays as it arrives.

**Codes, not accounts.** Each student gets a random 8-character code (30 unambiguous symbols; no I, L, O, U, 0, 1). Edward maps
codes to students offline; no student name is stored or printed anywhere. The app asks for the code once and keeps it in the
Keychain. **The code replaces the shared `APP_ACCESS_TOKEN`** on every endpoint: a leaked shared token could not be revoked for
one student and was shipped inside every copy of the app, whereas a code can be turned off alone, carries its own meter, and
is the thing the cap is counted against. The server checks the code on every request. `scripts/codes` (run locally by Edward)
creates, lists, tops up and disables codes (`docs/how-to-run.md`).

**The cap: 8 hours a month per code.** **Counted time is the real time the student is actively working** (rule changed 2026-11-14,
see the amendment below): the gaps between consecutive activity moments (ink, a question, the tutor looking or answering because
of the student, the student's live voice talk), where any gap longer than 60 seconds counts as zero (they walked away or sat idle).
Nothing is charged ahead of time: the first moment of a session charges 0 seconds, and stopping charges nothing after the last
moment. The server meters from requests it already receives (a valid `/api/watch` look, `/api/ask` or `/api/consult` question) plus
a heartbeat (`POST /api/heartbeat`, every 30 seconds, sent by the app only while a problem is open and there is student activity
it has not reported yet). A heartbeat is not activity by itself: it carries `seconds_since_activity`, how long ago the student's
last real ink or live talk was, and the server charges the gap from that moment. A student who opens a problem and leaves the iPad
on the table accrues about nothing. The month is the calendar month in America/Vancouver and resets on the 1st. At 80% used, the
tutor says how much is left (once a month); at 100% the tutor says the month's hours are used up and to ask Edward for more,
watching and asking stop (the server refuses with `hours_used_up`), and drawing still works. The app always shows the minutes
left. A top-up adds time to the current month only.

**Amendment, 2026-11-14: the counted minute is now real working time (Edward's decision).** The first rule charged every activity
event a 2-minute window forward (`ACTIVITY_WINDOW_SECONDS = 120`, `covered_until`) and the app sent a heartbeat every 60 seconds
while there had been activity in the last 2 minutes. On Edward's own device test (UTC) that over-charged: the problem opened at
11:00:56 with 480 minutes left; the 11:01:58 heartbeat already showed 477 (3 minutes gone after 1 real minute); he wrote until about
11:04, then idled, and at 11:06 the meter read 473. He had written for about 3 minutes and paid about 7. Why: every event was
pre-charged 2 minutes, and the heartbeat kept re-arming the window while he was only thinking. The new rule counts only the gap
between real moments, capped at 60 seconds, with no pre-charge (`chargeFor` in `server/lib/students.ts`, one atomic SQL statement,
new column `usage_months.last_activity_at` from `server/db/migrations/002_last_activity_at.sql`; `covered_until` is kept but
unused). Replayed through the new rule, his session (a stroke about every 10 seconds from 11:01:00 to 11:04:00, heartbeats every 30
seconds) costs about 160 seconds, not 7 minutes. Trade-offs, on purpose: opening a problem or a live session is not work; two moments
more than 60 seconds apart do not charge the gap between them even if the student was quietly thinking; a heartbeat can lose up to
30 seconds of trailing ink if the problem is closed before the next beat.

**Storage.** Neon Postgres on the Vercel Marketplace, Free plan (no payment method; 1 GB, 100 CU-hours of compute a month), provisioned
into the `pencil-tutor` project in the Vercel team. Two tables (`students`, `usage_months`; `server/db/migrations/001_students.sql`,
additive only), raw SQL through one module (`server/lib/db.ts`), every lookup on a unique or primary-key index, one running total per
student per month (never recounted), no OFFSET. Measured on the deployed function: 5 to 23 ms per query warm, 53 to 82 ms for the first
query after idle (Neon's free compute sleeps after 5 minutes idle). The app calls `GET /api/me` when it opens and when a problem opens, so
the database is awake before the first real request.

**Premium live voice.** GPT-Live-1 (amendment 12) is reachable only when the student's plan has `live: true`, which defaults to false
(`scripts/codes live CODE on`). With live off, the app never calls `/api/live-session` and shows no live controls; the server answers 403
`live_not_in_plan` to anyone else.

**Cost model per counted hour (USD at list price; CAD at 1 USD = 1.425 CAD).** Prices read 2026-11-14.

| item | price | source | per counted hour |
|---|---|---|---|
| A page look (`gpt-6.1-sol`, 1,841 input tokens, about 45 output) | $2 / $10 per million tokens | `server/lib/pricing.ts` (OpenAI pricing page, 2026-11-14); tokens **measured** on the deployed server, 4 looks | about $0.0041 each; **assumed** 60 to 120 looks an hour: $0.25 to $0.49 |
| Tutor voice, ElevenLabs v4 Turbo | $0.04 per 1,000 characters | https://elevenlabs.io/pricing/api (2026-11-14); 1 character = 1 credit **measured** (401 test characters used 401 credits) | **assumed** 2,000 to 10,000 characters an hour (1,000 characters is about 62 seconds of audio, measured): $0.08 to $0.40 |
| A spoken question (`gpt-6.1-terra` answer plus transcription) | $1 / $5 per million tokens; transcription price **not checked** | `server/lib/pricing.ts` | model part about $0.003 each; **assumed** 5 to 10 an hour: under $0.03 plus transcription |
| Database (Neon Free), hosting | $0 | Vercel Marketplace plan `free_v3` | $0 (the Vercel plan itself is **not confirmed**, see below) |
| **Total per counted hour** | | | **light $0.34 (CA$0.48), typical $0.59 (CA$0.83), heavy $0.92 (CA$1.31)** |

At the full 8 hours: typical $4.68 (CA$6.67), heavy $7.36 (CA$10.49), against CA$19 of revenue. Premium live adds $3.00 an hour of open
session ($0.05 a minute, `gpt-live-1` model page) on top of the looks: about $3.4 an hour, or about $27 (CA$39) for 8 hours, more than
the CA$19 price, so a live plan needs its own price. The looks per hour and characters per hour are assumptions until real sessions
are logged; the server logs `text_chars`, `tts_chars_month`, estimated cost per look and counted minutes for each student, so the first
real month settles them.

**Capacity limit, not just cost.** The ElevenLabs account is on the **Creator plan ($22 a month list)**, whose character allowance for
this account is **157,028 credits a month and cannot be extended** (`allowed_to_extend_character_limit: false`; 33,812 already used this
period, resetting 2026-11-22). At the assumed 2,000 to 10,000 characters per counted hour, that is roughly 16 to 78 counted hours a month
across all students (2 to 10 students using the full 8 hours). When it runs out ElevenLabs refuses; the server then speaks through OpenAI
(a different voice) and logs `voice_fallback` with the reason. Going past a handful of students needs a larger ElevenLabs plan. That is
Edward's call and costs money; it is not decided here.

**Not confirmed.** Whether the Vercel team is on the Hobby plan (Hobby is for non-commercial use; a paid product likely needs Pro): not
checked. The ElevenLabs API key for the server could not be created from the command line (see `docs/how-to-run.md`).

### Amendment 14 (2026-11-14): high school math runs on gpt-6-luna; problems carry a level; every look logs its tokens and cost

Edward: "for high school math, you don't need a frontier model ... college-level and harder, then 6.1, but for high school math,
Luna or Terra will do." The question was whether the cheaper model still catches mistakes. It was measured, not assumed.

**What changed.**
- Every `/api/watch`, `/api/ask` and `/api/consult` call logs the model, input, cached-input, output and reasoning token counts, the
  provider time, and an estimated USD cost from `server/lib/pricing.ts` (counts and labels only, never text or pictures).
- Problems have a `level` (`high_school` by default, or `advanced`). Config maps `high_school` to `gpt-6-luna` for watch and for
  ask/consult, and `advanced` (college level and harder) to `gpt-6.1-sol`. Nothing in the bank is advanced yet; the route exists so a
  harder problem set needs no code change. Both levels are env-overridable: `WATCH_MODEL`, `ASK_MODEL`, `WATCH_EFFORT`, `ASK_EFFORT`
  for high school, the same names with `_ADVANCED` for advanced. Nothing bigger than that was built.
- The iPad Debug build keeps a copy of each page picture sent to watch or consult next to the session log (Release never does), so
  Edward's real handwriting can be pulled off the iPad for the next eval.
- The default live voice is `meridian` (Edward's choice, 2026-11-14), replacing `gleam` in amendment 12.

**The eval.** `server/eval/`: 30 synthetic handwritten BC Math 9 pages with known answers (8 correct and finished, 7 correct but
unfinished, 15 wrong at a known line: sign, distribution, combining like terms, moving a term, dividing or multiplying only one side),
rendered 1024 x 544 PNG like the app sends. Each page went through the real `handleWatch` and `handleConsult` with each candidate
model, 2 repetitions per page (1 for Gemini 4 Argon). Results: `server/eval/results/main2.md` and `.jsonl`. Pages are fonts with
jitter, **not real handwriting**.

| model | watch: exact first wrong line | watch: false alarms | consult: exact line | consult: false alarms | schema failures | watch p50 / p90 | cost per watch look | cost per consult look |
|---|---|---|---|---|---|---|---|---|
| gpt-6.1-sol (old watch default) | 30/30 | 0/30 | 30/30 | 0/30 | 0 | 3.1 s / 4.2 s | $0.00243 | $0.00315 |
| gpt-6.1-terra (old ask default) | 30/30 | 0/30 | 30/30 | 0/30 | 0 | 2.6 s / 3.4 s | $0.00128 | $0.00179 |
| **gpt-6-luna (new default)** | 30/30 | 0/30 | 30/30 | 0/30 | 0 | 2.5 s / 3.3 s | **$0.00016** | **$0.00022** |
| gpt-6-luna, low effort | 29/30 | 0/30 | 29/30 | 0/30 | 0 | 3.2 s / 4.4 s | $0.00015 | $0.00015 |
| gpt-6.1-terra, low effort | 30/30 | 0/30 | 29/30 | 0/30 | 0 | 2.5 s / 2.8 s | $0.00123 | $0.00113 |
| gemini-3.8-flash | 30/30 | 0/30 | 30/30 | 0/30 | 0 | 4.3 s / 5.6 s | $0.00265 | $0.00261 |
| gemini-4-argon (1 repetition) | 15/15 | 0/15 | 15/15 | 0/15 | 0 | 6.8 s / 9.7 s | $0.00648 | $0.00445 |

Consult accuracy is read by a judge model (`gpt-6.1-sol`, low effort) that only extracts what the report claims. Provider errors: 0
across all runs.

**Choice rule and result.** The default for high school becomes the cheapest model within 1 page of Sol's first-wrong-line accuracy
with no more false alarms than Sol. That is `gpt-6-luna` for both roles (equal to Sol on all four scores). Low effort saved under
$0.0001 a look and lost one page, so effort stays at the provider default.

**Cost per minute of session, watch plus consult only (voice not included).** A real 3-minute iPad session made 7 watch looks and 6
asks. Priced at the measured per-look costs: before (Sol watch, Terra ask) 7 x $0.00243 + 6 x $0.00179 = $0.0278 per 3 minutes, **US$0.0093
per minute (CA$0.0132)**; after (Luna) 7 x $0.00016 + 6 x $0.00022 = $0.0024 per 3 minutes, **US$0.0008 per minute (CA$0.0012)**, about 11
times less. The unmeasured US$0.05 per minute estimate was about five times too high even before the change. The voice
($0.05 per minute for GPT-Live-1) is unchanged and now dominates. These are estimates from a price table (OpenAI pricing page, fetched
2026-11-14), checked against token counts the API reported, not an invoice.

**What the numbers do not settle.**
- The pages are synthetic. Real handwriting is messier; no model was tested on it. The Debug capture exists to fix that.
- 15 wrong pages x 2 repetitions is a small set. Two earlier fixtures (a half-written line that read as a complete wrong equation) made
  every model flag a "correct" page; they were fixed, rerun, and are the one place Luna's watch differed from Sol's: on the line
  `8x - 1 = 3x`, which looks finished, Luna interrupted twice where Sol and Terra waited twice. If real use shows Luna interrupting on
  lines still being written, set `WATCH_MODEL=gpt-6.1-terra` (half the saving, same accuracy here).
- `/api/ask` (the spoken-question fallback) shares the ask model but was not evaluated on free-form questions; only page reading
  (`/api/consult`) was.
- Claude Haiku was not run: no Anthropic key exists in the environment or in `tutoring/.env.local`, so no provider was added.
- The `advanced` route has no problems on it and no eval.
- Google raises Gemini 4 Argon prices on 2026-12-01 ($4 / $20) and Gemini 3.8 Flash on 2027-01-01 ($1.50 / $7.50); the price table
  switches on those dates.
- The recalled note about the Vals AI SAGE benchmark was partly wrong. The archived SAGE v1 board (2026-10-08, not 11-12) lists Gemini 4
  Argon 53.65%, GPT-6 Luna 48.09%, GPT-6.1 Sol 46.54%, Claude Haiku 5.5 45.78%. Luna did beat Sol there, but Argon led those
  three, and v1.1 has replaced v1 (https://www.vals.ai/benchmarks/sage-v1). This is a different task from watching live pages.

### Amendment 15 (2026-11-14): the page is endless downward, and the lasso is confirmed

Edward: "add a lasso tool and/or the selection tool to junk delete and make it infinite canvas-like." Code in `ios/PencilTutor/Drawing/`
(`InkCanvas.swift`, `PageSnapshot.swift`), `Views/MarksOverlay.swift`, `Session/TutorSession.swift`. Not yet run on the iPad.

**Lasso.** (Superseded in part by Amendment 16: the system tool picker is gone, the lasso is now a wheel item, the page also scrolls
sideways and zooms.) The system tool picker (`PKToolPicker`) already carries the lasso in its default items (pens, eraser, lasso, ruler). The
header only says "default tool items", so the app does not trust that: on every problem screen it reads `picker.toolItems`, logs the
item kinds (`tool_picker_items`, with `has_lasso`) and adds a `PKToolPickerLassoItem` itself if one were ever missing. A lasso
delete, cut, paste or move changes the drawing and arrives through `canvasViewDrawingDidChange` like a written stroke, so the revision
bumps, the idle timer restarts and the tutor looks again once the page has been still for 2.5 s. A loop that only selects changes no
ink, so it starts no look (`drawingRevision == lastLookRevision` keeps the look policy quiet); while a lasso gesture is down it holds
the look back like a pen that is down. `ink_changed` now logs `strokes_delta` and `last_tool` (negative delta = deleted or erased,
zero with the lasso = moved), `tool_began` marks every lasso or eraser gesture and `lasso_selection_changed` marks a selection. A red
mark whose ink was deleted or moved away is removed (`marks_cleared`, why: ink deleted or moved away).

**Endless page (vertical).** The canvas scrolls vertically only: no horizontal scroll (content width = view width), no zoom (range
pinned to 1), `contentInsetAdjustmentBehavior = .never`. Finger scrolls and the Pencil writes (the default drawing policy);
`--any-input` UI tests keep one-finger drawing and scroll with two fingers. Page height = lowest ink + one screen of blank paper,
never less than one screen (`PageGeometry.contentHeight`); it grows as the student writes, shrinks when ink is deleted, and follows a
rotation. Drawing coordinates are content coordinates, so ink, line boxes and marks share one coordinate space ("page points").

**Tutor marks.** `MarksOverlay` lays the marks out in page points and shifts that layer by the canvas's scroll offset
(`CanvasViewport`, published by the session), clipped to the visible canvas. The callout is placed against the whole page height.
When the tutor circles a line that is off screen, or too close to the screen edge for its callout, the page scrolls to put the mark
about a third of the way down (`scrolled_to_mark`). "Erase page" returns to the top and shrinks the page to one screen (undo
restores both). The server returns a line number, not a position, so marks come from the app's own line boxes.

**Page picture (`PageSnapshotter.region`).** The server still rejects any picture whose longer side is over 1024 px, so the rule keeps
that and keeps the cost of a look about constant:
1. A page that fits the first screen gets exactly the picture it always did (screen width x height, scale 1024 / longer side).
2. Ink below the screen extends the picture down to the lowest ink plus 40 pt, and the scale drops so the longer side stays within
   1024 px (1180 x 1540 pt page: 0.665).
3. The scale never drops below 0.55 (35 pt handwriting stays about 19 px tall). Past about 1860 pt of page the window slides: it ends
   under the lowest ink and starts as far up as fits. Lines whose middle is above the window are not sent that look (the numbers in
   the margin and the `lines` boxes are measured from the window's top edge), so the tutor reads the newest work.
`look_started`, `ask_started` and `live_consult_started` log `image_px`, `region` and (for looks) `lines_sent`.

**Not settled.** Whether the Pencil lasso feels right with the picker's own selection menu, whether the overlay stays glued during a
fast fling (the overlay follows SwiftUI state, one step behind UIKit; if it lags on the iPad, host the marks inside the scroll view),
and how the tutor reads a 0.55-scale page of real handwriting: no eval covers pages taller than one screen.

### Amendment 16 (2026-11-14): edge-to-edge page, floating chrome, our own tool wheel, an endless page in every direction

Edward: "a lot of white space under the problem section... just make good use of white space"; "I really like the way Concepts put that
tool wheel... I want to use it like that for real." The first device log showed a 660 pt tall canvas on a landscape iPad: the problem
card, control bar and dividers took the rest. Inspiration is Concepts' mechanics and feel only; the icons (SF Symbols), colours and
layout are ours. This replaces the system `PKToolPicker` of amendment 15 (and its `tool_picker_items` / `tool_picker_shown` logs) and
the vertical-only page. Not yet run on the iPad. Code: `Drawing/InkCanvas.swift` (canvas, wheel logic), `Drawing/PageSnapshot.swift`
(`PageGeometry`, `PageSnapshotter`), `Views/ProblemScreen.swift` (layout, wheel drawing), `Views/ProblemCardView.swift`,
`Views/MarksOverlay.swift`, `Session/TutorSession.swift`.

**Layout.** The page fills the screen edge to edge (under the status bar and home indicator); the navigation bar is hidden. Everything
else floats on `.ultraThinMaterial` over it: a Back button and the problem card top-left (a card with the problem set as written;
tap folds it to a one-line pill, tap again opens it; the choice is remembered in `@AppStorage "problemCard.collapsed"`); one slim
action pill top-right (Check my work, the voice control, Clear marks and Erase page as icon buttons, the hours chip, the busy spinner);
the caption banner on its own row under the pill, so it never covers an action (still goes on tap or when the student writes); the
tool wheel's handle in a bottom corner. On a narrow window the pill drops under the card (`ViewThatFits`). Every accessibility
identifier is unchanged; new ones: `backButton`, `toolWheelHandle`, `toolWheel_<pen|marker|eraser|lasso|undo|redo>`,
`toolWheel_colour_<black|blue|red|green>`, `toolWheel_width_<thin|medium|thick>`. The old stack (card about 90 pt + control bar about 56 pt +
dividers + navigation bar) is gone, so the canvas is the screen: the `canvas_on_screen` log line gives the new size to compare with
the 660 pt before.

**Tool wheel.** (Superseded by Amendment 17: replaced by an always-visible tool rail.) A 56 pt round handle (default bottom-right, drag it and it snaps to the nearest edge; position kept in UserDefaults)
shows the current tool and colour. Tap: a ring opens, the handle slides inward just enough for the whole ring to fit on the page.
Inner ring: pen, highlighter, eraser, lasso (`PKLassoTool`), undo, redo. Outer ring: black, blue, red, green and thin, medium, thick.
A tool tap selects and closes; a colour or width tap changes the pen and keeps the ring open (choosing one while the eraser or lasso
is on goes back to the last inking tool); writing, scrolling or tapping the handle closes it. Highlighter + black is yellow. The eraser
is the vector eraser (a touch removes a stroke). Undo and redo go through the canvas's `undoManager`, so Erase page is undone from the
wheel as before. The pen, colour and width are kept for the next problem. The Pencil's double-tap and squeeze (`UIPencilInteraction`)
do what Settings > Apple Pencil says: switch to the eraser and back, switch to the previous tool, or open the wheel; ignore and system
shortcuts do nothing. The wheel also shows under `--any-input` (UI tests): it is one closed handle in the bottom-right corner, outside
the area the tests draw in, so showing it exercises the real tool path for free. `TutorSession.penDidTouchDown(tool:)` and the lasso
flow through `canvasViewDrawingDidChange` are unchanged. Logs (labels only): `wheel_ready` (undo manager present, Pencil actions),
`wheel_opened` / `wheel_closed` (reason), `tool_selected` (tool, colour, width, source), `wheel_undo` / `wheel_redo` (and `_unavailable`
with the reason), `pencil_double_tap` / `pencil_squeeze` (action, result), `wheel_handle_moved` (edge), `problem_card_toggled`.

**An endless page in every direction.** Fingers pan and pinch (0.5x to 3x), the Pencil writes. Drawing coordinates are still the
canvas's content coordinates and are unzoomed ("page points"); the scroll view reports zoomed sizes, and screen = page x zoom - offset.
A scroll view has no negative content coordinates, so: the first screen sits 3000 pt in from the top-left corner (`homeReserve`), the
page is the first screen and the ink plus one screen on every side (`PageGeometry.contentSize`), and it grows right and down by
resizing (`page_grew`, direction + new size). If ink comes within a screen of the left or top edge (more than about 1800 pt left of or
above the first screen) the whole drawing, the scroll position and the tutor's marks move right/down by `reanchorShift` (a multiple of
100 pt, back to a 3000 pt reserve), `page_reanchored` is logged, and the undo history is dropped, because its steps describe the old
coordinates; a look in flight at that moment is discarded by the existing same-ink check. That is the only time coordinates change.
Erase page resets zoom to 1 and scrolls back to the first screen. `zoom_settled` logs each finished pinch, with the content size the
scroll view reports against the size expected (if they differ the session corrects it and logs `zoom_content_corrected`).

**Tutor marks and the picture.** `MarksOverlay` multiplies the mark by the zoom and shifts by the offset; only the circle scales, the
callout keeps its reading size. The page scrolls to a mark that is off screen or within 80 screen points of an edge, in both directions
(`PageGeometry.offsetToReveal`), and the zoom stays as the student set it. `PageSnapshotter.region` is now 2D: ink on the first screen
gives the same picture as always (first screen, longer side 1024 px); otherwise the box around all the ink + 40 pt, at least one screen,
joined with the first screen when the ink touches it, scale down to fit 1024 px; below the 0.55 scale floor (about 1860 pt) the window
slides, as large as the limit allows, ending just past the newest line in both directions. Lines whose middle is outside the window are
not sent. Line boxes go to the server relative to the picture's top-left corner (`LineWire(regionOrigin:)`). On a picture wider than
one screen the line numbers sit beside their lines instead of in the far-left margin. The line grouper only uses relative distances
(vertical overlap, a 160 pt side gap, the leftmost ink), so it does not care where on the plane the ink is (unit tested at +6000/+5000).

**Not settled (unverified on a device).**
- PencilKit zoom: whether `PKCanvasView.contentSize` is scaled by the zoom like a plain `UIScrollView` (the code assumes so and logs the
  difference), whether the Pencil keeps writing at the right size and place while zoomed, whether a pinch conflicts with the Pencil's
  first touch, and whether stroke width on the page changes with the zoom.
- Handwriting size: if strokes are drawn at a constant on-screen size, zooming in makes handwriting smaller in page points. The tutor's
  0.55 scale floor, the line grouper's 160 pt side gap and the 80 pt callout allowance all assume about 35 pt writing at zoom 1.
- The overlay follows SwiftUI state one step behind UIKit; a fast fling or pinch may show the circle lagging for a frame or two.
- The 3000 pt reserve and 100 pt shift steps are guesses; a re-anchor drops undo and has not been seen on a device.
- Whether an edge-to-edge page under the status bar and home indicator feels right, and whether the floating pill covers writing at the
  top right (the caption row and the pill are about 60 pt tall; the card folds away).
- A two-handed student: a resting palm on the wheel handle opens it; the handle is outside the default writing area but it is not
  hidden while writing.

### Amendment 17 (2026-11-14): an always-visible tool rail replaces the wheel; the floating chrome stops overflowing

Edward tried the wheel on the iPad: it closed after every pick, so each tool or colour change cost a reopen, and its handle took space.
"Make sure the UI is good to the point that I don't hate it. It's chill. I have to be able to use it to do stuff." This supersedes the
**Tool wheel** part of Amendment 16 (the radial ring, the handle, its drag and snap, open/close, the saved handle position, the
`wheel_*` logs). Everything else in 16 stands. Branch `tool-rail`. Code: `Drawing/InkCanvas.swift` (`ToolRailModel`, `ToolRailStyle`,
`RailGestureRules`, the finger taps), `Views/ProblemScreen.swift` (`ToolRailView`, the action pill), `Views/ProblemCardView.swift`.

**Tool rail.** One slim floating capsule on the left edge, directly under the Back button, always on screen; it never opens, closes or
moves. 48 pt wide, about 615 pt tall (fits the iPad 9th gen landscape, 810 pt, and the 744 pt iPad mini landscape; a shorter window
makes it scroll rather than clip). Top to bottom: pen, highlighter, eraser, lasso; hairline; black, blue, red, green; hairline; thin,
medium, thick; hairline; undo, redo. Every control has a 44 x 44 pt hit target; the chosen tool, colour and width get a filled
highlight and ring (no size change, so nothing shifts). The swatches show the highlighter's colours while the highlighter is on (black
shows yellow). Choosing a colour or width while the eraser or lasso is on returns to the last ink tool (unchanged rule), so
"eraser, then red" is two taps and the rail never has to be reopened. The pen, colour and width are still remembered (same
`toolWheel.*` UserDefaults keys, so the saved pen survives). Pencil double-tap and squeeze still do switch-eraser / switch-previous;
"show palette" now does nothing visible (there is nothing to show) and logs `rail_always_visible`. Identifiers: `toolRail`,
`toolRail_<pen|marker|eraser|lasso|undo|redo>`, `toolRail_colour_<black|blue|red|green>`, `toolRail_width_<thin|medium|thick>`.

**Finger gestures.** Two-finger tap on the page is undo, three-finger tap is redo (Concepts-style). Two `UITapGestureRecognizer`s on the
canvas, `allowedTouchTypes = [direct]` (fingers only, never the Pencil), `cancelsTouchesInView = false`, running alongside the canvas's
own pan and pinch (a tap that lifts quickly never moves far enough to start either); the two-finger tap waits for the three-finger one to
fail so a three-finger tap is never also an undo. The rule (`RailGestureRules`) is a pure function and unit tested.

**Logs (labels only).** `rail_ready` (was `wheel_ready`; no handle field), `tool_selected` (source `rail`, `double_tap`, `squeeze`),
`rail_undo` / `rail_redo` (were `wheel_undo` / `wheel_redo`; now one line with `result` = `done`, `nothing` or `no_undo_manager`, plus
`can_undo`, `can_redo`), `gesture_undo` / `gesture_redo` (same fields), `pencil_double_tap` / `pencil_squeeze` (result may be
`rail_always_visible`). Gone: `wheel_opened`, `wheel_closed`, `wheel_handle_moved`, `*_unavailable`.

**Overflow and consistency pass.** Sources: Apple HIG (buttons: hit target at least 44 x 44 pt with room around it; layout) and Vercel's
Web Interface Guidelines (match visual and hit targets, 44 on touch; no layout shift; loading buttons keep their label; icons have
labels; gestures have tap alternatives; respect safe areas; no truncated controls). Rules now in the code:
- Every label in the action pill is one line (`lineLimit(1)` + `fixedSize`), never cut off, never wider than its capsule. The row tries
  full labels, then short ones (Check, Ask, Talk, Reconnect, Connecting...), then the pill under the card (full, short), then
  icon-only buttons; the words stay as the accessibility label. `ViewThatFits` picks the first that fits.
- No layout shift: a button's width is held at its longest wording (Tap to ask / Tap to send; Mic on / Muted), and the busy spinner
  replaces the Check icon instead of adding a spinner at the end of the pill. While listening the visible words are "Tap to send"
  (red capsule, waveform); VoiceOver still says "Listening... tap to send".
- Hit targets: the action pill's buttons and the Clear / Erase icons are 44 pt tall (the Back button was already 44); the pill is exactly
  the Back button's height so the top row lines up. The folded problem pill is 44 pt tall and shows "Problem" instead of an ellipsis
  when the prompt is too long. The caption wraps to its words instead of cutting off at four lines.
- One material and shadow for all floating chrome (`.thinMaterial`, same soft shadow); one corner language (capsules and 12-24 pt
  continuous rounded rectangles). Check my work is the one solid colour; Tap to ask is a soft tint, solid red only while listening.
- The rows lower in the chrome column (blocked banner, test status) leave the rail's 56 pt gutter on the left.
The expanded problem card still wraps a long problem across lines on purpose; that is the problem text, not a label.

**Verified on the iPad 9th gen (device 00008030-0002101902D0202E), 2026-11-14.** UI tests ran on the device: the rail exists with no tap;
eraser then red returns to the pen with the rail still there; undo from the rail removes one stroke; the rail's frame is under the Back
button, left of the card, inside the screen, every rail control at least 44 x 44; the pill buttons are inside the screen, 44 pt hit
targets, not overlapping the rail, portrait and landscape, card open and folded. Screenshots were read by eye.

**Not verified (needs Edward's hands).** A real Pencil next to the rail (palm on the rail while writing: the rail is 48 pt on the left
edge, a left-handed or palm-down writer may brush it; the system's palm rejection applies to the Pencil's contact only, a resting palm
on a finger-touch button still taps it); two- and three-finger taps against the real pan and pinch (the UI tests cannot do multi-finger
taps), and against iPadOS's own three-finger gestures; finger-drawing mode (no Pencil paired) where a two-finger tap might also leave a
dot; the voice states "Connecting voice...", "Reconnect voice" and "Listening" (laid out by the same rules, not captured); a window
shorter than 700 pt (Split View), where the rail scrolls.

### Amendment 18 (2026-11-14): the course banks are wired in; pick a course, then a problem; the tutor knows the course

Edward asked for the new course banks (`shared/courses/<slug>/problems.json`) to be playable. Branch `wire-courses`.

- **Manifest and bank.** `server/scripts/build-courses.ts` (`npm run build-courses`) reads the original 12 (`shared/problems.json`, listed
  as the course `bc-math-9-unit-3`) and every folder under `shared/courses/`, validates each problem, fails on a duplicate id across all
  courses, and writes `shared/courses/index.json` (slug, title, group, grade, level, count, file) and the server's `server/data/problems.json`
  (courses plus trimmed problems: 1,024 problems, about 430 KB at 15 courses). A new folder needs no code change; an optional `course.json`
  sets the title, group and grade, otherwise they are inferred from the folder name and level. `test/courses.test.ts` fails when a generated
  file is stale. This replaces `npm run sync-problems`.
- **iPad.** `ProblemListView` is now the home: a course picker grouped Elementary (grades 5-7), High school (8-12), College, then the
  course's problem list, then the existing problem screen. The last course is remembered (`lastCourseSlug` in UserDefaults) and opens at
  launch; Back goes to the picker. The bundle step (`ios/Scripts/bundle_problems.py`) writes `courses.json` and one `course-<slug>.json`
  per course (prompts only, no solutions; about 270 KB) and fails the build when a folder is missing from the manifest. `--open-problem <id>`
  finds the course itself. Code: `Core/Courses.swift`, `Core/CourseCatalog.swift`, `Views/ProblemListView.swift`, `Views/AppToolbar.swift`.
- **Problem card.** The fixed "Solve for the letter" line is replaced by the course name. The prompt font steps down with length
  (26, 23, 20, 18 pt for 60, 110, 170 and longer characters) so a 260-character word problem fits in about six lines inside the 460 pt card; a
  bracketed run such as the matrix `[1 2; 3 4]` is kept in one piece.
- **Tutor level.** Every watch, ask, consult and live prompt now begins with the course and who the student is (`audienceFor`, `lib/policy.ts`):
  grade 5-7 gets short sentences and simple words, grade 8-12 the words of the course, college the standard terms. A problem with no course
  keeps the original Grade 9 tutor. Requests log `course` (the slug) next to `level`.
- **Model tier is a per-course switch, default standard (decided by the coordinator, 2026-11-14).** Every course, the three college
  ones included, runs on the cheap tier (`gpt-6-luna`). A course opts into the frontier tier (`gpt-6.1-sol`, about ten times the cost per
  look, which the CA$19 plan cannot carry) only with `"tier": "advanced"` in its `course.json`; `build-courses` validates it, writes it to
  the manifest and the server bank, and `levelOf` (`lib/problems.ts`) reads it. A problem whose own `level` is `advanced` also escalates;
  the bank's `college` level alone does not. Each watch, ask and consult request logs `course`, `tier` (`standard` or `advanced`) and
  `level`. **Escalating a course needs measured handwriting results first**: the only eval (amendment 14) covers high school pages, and the
  advanced route has not been measured on calculus or linear algebra handwriting. Run that eval before setting any course to advanced.
- **Needs a deploy.** The server must be deployed for the new courses to be tutored (it looks problems up by id in its own bundled copy).
  Until then a new app build would get 422 `unknown_problem` for every course problem except `u3-..`.

### Amendment 19 (2026-11-15): line grouping follows the written lines; writing starts below the problem card; the card sets real maths

Three faults the self-driving handwriting replay found (`docs/evals/2026-11-15-handwriting-replay.md`). Branch `line-grouping-and-card`.

- **Line grouping (`Core/LineGrouping.swift`).** Everything is measured in `letter`, the median height of the strokes that are not
  dashes or specks (so it does not move with how big the student writes). Steps: (1) a stacked fraction (a flat bar with a row of
  writing right above and right below it, about as close on both sides, with no stroke crossing the bar) is one piece; (2) pieces whose
  heights overlap form a band; (3) a band that touches several lines is cut at its thinnest slice (ink per height) when that slice holds
  at most `valleyShare` (0.4) of the thinner row around it, never through a fraction; (4) a band holding only small marks (a raised
  exponent, a subscript, a comma) attaches to the nearest line it stands beside (within 0.8 letter vertically, 1.2 horizontally);
  (5) a stroke taller than 2.5 letters (a scribble, a big bracket) joins the line its middle falls in without stretching it; (6) work far
  to the right is a side calculation, as before. The result does not depend on the order strokes arrive in (tested). A matrix is one line
  of work: its rows stay together. Tested in `LineGrouperTests` (raised and lowered marks, a lone far mark, two fraction lines that nearly
  touch, a 7's top bar, a descender into the next row, drifting rows, shuffled input).
  **Measured offline** by running the real `LineGrouper` over the replay's ink (`ink_script.py stress`: every drawable problem in every
  course at five spacings and wobbles, 2,570 pages, a page agrees when every group holds strokes of exactly one written line and the count
  matches): 985 agree before, 2,404 after. At the normal spacing 265 of 514 before, 505 after; at spacing 0.6 and 0.4 of normal, and with
  twice the wobble, 201 to 500, 175 to 478, 185 to 489, 159 to 432. The same harness reproduced exactly the five documented device
  disagreements on the original 24 cases (before), and agrees on all 24 after.
- **The card no longer covers the first line.** The page's origin (where a first stroke goes) is placed `clearance` points below the top
  of the screen, where `clearance` is the bottom edge of the problem card (measured in `ProblemScreen`, converted in
  `TutorSession.topClearance`) plus 12 pt: `PageGeometry.homeOffset`. The paper above is blank. While the page is blank and unmoved the
  home follows the card (it folds, unfolds or rewraps); once there is ink or the student has scrolled or zoomed nothing moves behind
  their back. A tutor mark under or within 12 pt of the card counts as out of view: `PageGeometry.offsetToReveal(topClearance:)` scrolls
  it clear (the mark lands at least clearance + 12 pt down). The pictures sent to the models are unchanged (the first-screen region is
  the same page rectangle). Logged: `page_home_placed.card_clearance`, `card_measured`, `scrolled_to_mark.card_clearance`.
- **Maths in the card (`Core/MathMarkup.swift`, `Views/MathViews.swift`).** A small reader for the notation the banks use in
  `prompt_plain` and the text of `prompt_parts` (`^(…)`, `^x`, `_{…}`, Unicode superscripts and subscripts, `√x`, `√(…)`, `∛(…)`,
  `[1 2; 3 4]`, `Σ_{k=1}^{20}`) turns it into nodes; SwiftUI draws them (Text with baseline offsets for exponents and indices, a drawn root
  with its overbar and index, a grid between brackets, bounds above and below a sigma, stacked fractions on a shared baseline). No web
  view, no LaTeX engine, no font download, nothing fetched: it works offline. **Why not KaTeX/SwiftMath/`prompt_latex`:** an engine
  would add a web view or a package to a 3 GB iPad for about thirty distinct constructs, and `prompt_latex` is not clean enough to feed
  one (it mixes `\text{…}` with raw Unicode and bare `√3/2` in one string, so a second parser would be needed for the exceptions); the
  plain form is complete for all 1,012 problems and is what the tutor and the logs use. Anything the reader does not recognise stays
  the text it was. Slash fractions in prose (`4/6 and 10/15`) stay slash fractions. The collapsed pill and the problem list use the
  one-line form (exponents raised, roots and matrices as characters). A test reads every prompt of every course and fails if markup
  is left raw or a character is lost; `CardGalleryTests` (opt-in, `CARD_GALLERY_DIR`) draws sample cards from all 15 courses to PNG.
- **Replay tooling.** `ink_script.py` gains `--gap-scale` (cramped lines) and `--jitter` (rushed hand), `cases --pick COURSE:PROBLEM
  --matrix --mistake-only`, and `stress`. A matrix written in one equation line counts as one line (`app_lines` 1).

## Risks
- Model judgment on real handwriting is unmeasured; the synthetic set is a
  floor check only. Mitigation: session log turns real use into the test.
- Free Apple ID signing expires the app every 7 days until a paid developer
  account exists.
- Xcode download is about 15 GB with 59 GB free on disk.
