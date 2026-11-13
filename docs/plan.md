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
  a PencilKit canvas below. Pencil-only drawing; finger scrolls.
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
- Voice `gleam` (default, set with `LIVE_VOICE`), chosen from the documented voice table (North American, feminine,
  recorded rather than generated), not by ear.

Cost: voice is $0.05 per minute of open session (billed per second, $3.00 per hour), plus the normal ask and watch model
rates for each page look. A session that sees no ink and no speech for 5 minutes closes itself (a chosen default). No claim
is made that it is cheaper, faster or better sounding than the old path; latencies and usage seconds are in the session log.

Plan and its review: `docs/live-voice-plan.md`, `docs/live-voice-plan.review.md` (verdict CUT; page summaries, auto
reconnect and hint-timing gates were cut). Server contract: `server/README.md`. Running it: `docs/how-to-run.md`.

## Risks
- Model judgment on real handwriting is unmeasured; the synthetic set is a
  floor check only. Mitigation: session log turns real use into the test.
- Free Apple ID signing expires the app every 7 days until a paid developer
  account exists.
- Xcode download is about 15 GB with 59 GB free on disk.
