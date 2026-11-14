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

**Lasso.** The system tool picker (`PKToolPicker`) already carries the lasso in its default items (pens, eraser, lasso, ruler). The
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

## Risks
- Model judgment on real handwriting is unmeasured; the synthetic set is a
  floor check only. Mitigation: session log turns real use into the test.
- Free Apple ID signing expires the app every 7 days until a paid developer
  account exists.
- Xcode download is about 15 GB with 59 GB free on disk.
