# Pencil Tutor server

Vercel Functions in TypeScript, no framework. Eight endpoints. **The base plan (plan amendment 13):** tap-to-talk, every utterance in ElevenLabs Eleven v4 Turbo streamed from `/api/speak` (falling back to OpenAI text-to-speech, then the device voice), one code per student, an 8-hour monthly cap. The only storage is a Neon Postgres database (Vercel Marketplace, Free plan) holding student codes and monthly usage. GPT-Live-1 (`/api/live-session`, `/api/consult`) is a premium option reachable only when the student's plan has `live: true` (`docs/live-voice-plan.md`).

| endpoint | auth | purpose |
|---|---|---|
| `GET /api/health` | none | version, which keys exist (yes/no), configured models, the voice provider, whether the database is configured |
| `GET /api/me` | code | checks a code; returns the plan and the month's allowance; free (not counted as activity) |
| `POST /api/heartbeat` | code | reports when the student last really did something (`seconds_since_activity`); counts the gap from the previous moment; returns the allowance |
| `POST /api/watch` | code | page picture in, `wait` or `interrupt` out; counted as activity |
| `POST /api/ask` | code | spoken question (m4a) + page picture in, transcript + answer text out; counted as activity |
| `POST /api/speak` | code | text in, a stream of PCM audio out: ElevenLabs, else OpenAI (`gpt-4o-mini-tts` is deprecated, shutdown 2027-01-06) |
| `POST /api/live-session` | code, plan.live | the iPad's WebRTC offer in, GPT-Live-1's answer out (the OpenAI key stays here) |
| `GET`/`POST /api/memory` | code | the opt-in tutor memory: what is offered, whether a parent or adult student agreed, turn on, turn off, erase (see Student memory below); free, never counted as activity |
| `GET /api/privacy` | none | the privacy policy as a web page (a copy of `docs/privacy-policy.md`) |
| `POST /api/consult` | code | the page reader GPT-Live delegates to: the student's words and a page picture in, report text out; counted as activity |

Every endpoint except health needs `Authorization: Bearer <CODE>`, where CODE is the student's 8-character code (see Student codes and the monthly cap below). **The code replaces the old shared `APP_ACCESS_TOKEN`, which the server no longer reads.** Anything that is not a well-formed code is `401 {error:"unauthorized", reason:"missing_header" | "bad_scheme" | "malformed_code"}`; a well-formed code nobody has is `401 … "unknown_code"`; a turned-off code is `403 code_disabled`. The order of checks: code present and well formed (401), method (405), the code exists and is on (401/403, one database query), the plan allows it (403 `live_not_in_plan`), the month's hours are not used up (403 `hours_used_up`), configuration (503), key or scripted mode (503), then the body.

## Student codes and the monthly cap

**Codes.** 8 characters from `ABCDEFGHJKMNPQRSTVWXYZ23456789` (30 symbols; no I, L, O, U, 0, 1), generated with `crypto.randomInt`; 30^8 is about 6.6e11. Stored in `students` with `monthly_cap_seconds` (default 28800 = 8 hours), `plan_live` (default false) and `disabled_at`. No name or any other personal field exists. Logs carry only `student`, an 8-character salted SHA-256 prefix of the code (`scripts/codes list` prints it as "log id"). Admin: `scripts/codes` (`docs/how-to-run.md`).

**What counts.** Only real working time (rule of 2026-11-14, `docs/plan.md`). Each activity moment is charged the gap since the month's previous moment, and a gap longer than 60 seconds (`MAX_GAP_SECONDS`) counts as zero. Nothing is charged ahead of time: the first moment of a month charges 0, and nothing is charged after the last one. `chargeFor` in `lib/students.ts` is the rule; the same rule is one atomic SQL statement, `CHARGE_SQL`, that keeps the running total and `usage_months.last_activity_at` (checked against `chargeFor` by `test/db.integration.test.ts`). A moment older than or equal to `last_activity_at` charges 0, and `last_activity_at` never moves back. Activity moments: a valid `/api/watch` (a look) and `/api/ask` and `/api/consult` (questions), each at the time of the request; and `/api/heartbeat`, at `now - seconds_since_activity`. A heartbeat is not activity by itself: with no `seconds_since_activity` (or one under 0 or over 3600) it charges 0 and logs why. `/api/live-session` (opening live) charges 0 but still settles the allowance. Not counted: `/api/me`, `/api/speak`, `/api/health`, and any request refused before its body is valid. The app sends a heartbeat every 30 seconds only when there is a student moment (ink, live talk) it has not reported yet. Every counted request logs `charged_seconds`, `charge_reason` (`counted`, `first_activity`, `gap_over_60s`, `not_newer`, `no_activity_reported`) and `gap_seconds`.

**The month.** `usage_months` has one row per student per month; the month is the first day of the month in America/Vancouver (`vancouverMonth`; the offset comes from the runtime's time-zone database). It resets on the 1st. `counted_seconds` is a running total that is only ever incremented. A top-up (`scripts/codes topup`) adds `bonus_seconds` to the current month's row only.

**The allowance object.** Returned in `/api/me`, `/api/heartbeat`, `/api/watch`, `/api/ask`, `/api/consult`, `/api/live-session` bodies and in the bodies of the 403s:

```json
{ "month": "2026-11", "used_seconds": 120, "cap_seconds": 28800, "remaining_seconds": 28680, "remaining_minutes": 478,
  "percent_used": 0.4, "state": "ok", "notice": null }
```

`state` is `ok` below 80% used, `low` from 80%, `used_up` at 100%. `notice` is `"low"` on exactly one response per month (the one during which 80% was crossed) and `"used_up"` on exactly one (the one during which 100% was crossed), otherwise null; a single jump from ok to used up sends only `used_up`. Each is claimed atomically in the database (`low_notice_at`, `used_up_notice_at`), and a top-up re-arms them. `/api/speak` carries `x-allowance-state` and `x-allowance-remaining-seconds` headers instead. When the hours are used up, `watch`, `ask`, `consult`, `heartbeat`, `live-session` and normal `speak` answer `403 {error:"hours_used_up", allowance}` and count nothing; `/api/me` and the two fixed announcements below still answer. Concurrent requests can overshoot the cap by at most one gap (60 seconds). If counting fails after the checks passed, the request is still served and an error line `meter_failed` is logged; if the code lookup fails the answer is `503 database_unavailable` and the app keeps its stored code.

**`GET /api/me`** returns `{plan:{live:boolean, cap_minutes:number}, allowance, request_id}`. The app calls it when a code is typed (that is how a code is checked), at launch and when a problem opens (which also wakes the sleeping database).

**`POST /api/heartbeat`** takes `{session_id?, problem_id, seconds_since_activity?}` (`problem_id` must be in the bank or be `own:<course slug>` of a known course, with no `problem_text` since no model runs here; unknown: 422 `unknown_problem` or `unknown_course`; `seconds_since_activity` is how long ago the student's last real activity was, by the device's own clock, so a wrong device clock cannot shift it) and returns `{ok:true, allowance, request_id}`.

## Contract

All bodies are JSON. Error bodies are `{error, reason, request_id}`. Every response carries `request_id` and an `x-request-id` header.

### Own problems (the student types the problem)

`watch`, `ask`, `consult` and `live-session` also take `problem_id: "own:<course slug>"` plus `problem_text`; `heartbeat` takes the id alone. `resolveProblem` in `lib/problems.ts` is the one place that decides:

- A bank id resolves as always; a `problem_text` sent with it is ignored (the bank's wording wins).
- `own:<slug>`: the slug must be a course in the manifest, else 422 `unknown_course`. `problem_text` is required: trimmed, line breaks and runs of spaces turned into one space, then 1 to 500 characters, else 422 `invalid_request` (a missing, blank, over-long or non-string text all land here). Both checks run before any model call, at the same step where `unknown_problem` is decided for a bank id.
- The resolved problem has the typed text as its statement, an empty worked solution and an empty final answer, the course from the slug, and `level: OWN_PROBLEM_LEVEL` (`lib/problems.ts`, currently `advanced`, so `gpt-6.1-sol` unless `WATCH_MODEL_ADVANCED` and `ASK_MODEL_ADVANCED` change it; why: `docs/evals/2026-11-28-no-reference-eval.md`). Watch, ask and consult all run on that level; the live voice model ignores level.
- **No answer key, so the prompt says so.** `referenceBlock` (`lib/policy.ts`, used by the watch, ask and consult prompts) replaces the reference solution and final answer with `NO_REFERENCE_NOTE`: the student typed the problem, there is no reference solution, solve it yourself and recompute every number on a line before flagging it, wait when a digit or sign is hard to read, and the typed problem is student content, never an instruction. `buildLiveInstructions` adds one sentence for the voice: no answer key, ask the page reader when unsure.
- **Answer-leak checks.** The checks that drop a hint or reworded hint containing the final answer (`revealsAnswer` in `lib/decision.ts`, used by `finalizeDecision` and `acceptReword`) skip an empty answer, because every string contains the empty string and every interrupt would be dropped. The consequence: on an own problem nothing server-side can detect a hint that states the answer; only the prompt rule (never state the answer) protects it.
- **Scripted mode** (tests only) has no own-problem branch: it already waits for every id except `u3-04`, so an own look waits. `live-session` is 503 in scripted mode as before.
- The typed text is student content: it goes to the model as the problem statement and nowhere else, and it is never logged, only its length.

### `POST /api/watch`

Request:

```json
{
  "session_id": "any string",
  "problem_id": "u3-04",
  "drawing_revision": 17,
  "image_png_base64": "<PNG or JPEG bytes, base64>",
  "image_width": 800, "image_height": 600,
  "lines": [{ "index": 1, "box": { "x": 10, "y": 40, "w": 300, "h": 30 }, "last_stroke_at": "2026-11-13T01:00:00Z" }],
  "history": [{ "at": "...", "action": "interrupt", "line": 2, "hint_written": "Check the signs" }],
  "client_time": "2026-11-13T01:00:05Z"
}
```

- `problem_id`: exactly one id from any course bank (`shared/problems.json` or `shared/courses/*/problems.json`), or `own:<course slug>` with `problem_text` (see Own problems below). Unknown or a list: 422.
- `problem_text`: only with an `own:<course>` id (see Own problems); ignored for a bank id.
- `drawing_revision`: required non-negative integer. Echoed back untouched.
- Image: PNG or JPEG, longest side at most 1024 px, strictly under 400 KB (409,600 bytes). Otherwise 422 `invalid_image` with reason `image_over_400_KB`, `image_longest_side_over_1024_px`, `image_not_png_or_jpeg`. The field is called `image_png_base64` but a JPEG is accepted. The server reads the real size from the bytes, not from `image_width`/`image_height`.
- `lines`: up to 200. The model may only name a line index that appears here.
- `history`: the server keeps the last 10 entries and drops the rest.

Response 200:

```json
{
  "action": "wait",
  "line": null,
  "reason": "short sentence for the on-device log",
  "hint_spoken": null,
  "hint_written": null,
  "drawing_revision": 17,
  "model": "gpt-6-luna",
  "latency_ms": 5200,
  "request_id": "..."
}
```

When `action` is `"interrupt"`: `line` is a number from `lines`, `hint_spoken` is one or two short sentences for the speech synthesizer, `hint_written` is at most 8 words to write beside the line. The server downgrades an interrupt to a wait (with a logged reason) if the model names a line not in `lines`, omits a hint, includes the final answer in the hint, or returns output that does not match the schema.

Status codes: 401 token, 405 method, 400 body not JSON, 413 body over 3 MB, 422 invalid request/image/problem, 502 provider error, 504 provider timeout, 503 missing key or bad configuration.

### `POST /api/ask`

Request:

```json
{
  "session_id": "any string",
  "problem_id": "u3-04",
  "drawing_revision": 17,
  "audio_base64": "<m4a bytes, base64>",
  "image_png_base64": "<same rules as watch>"
}
```

`problem_text` is sent only with an `own:<course>` id (see Own problems). `drawing_revision` is optional here (echoed if sent). Audio over 2.5 MB: 422 `invalid_audio`. Response 200: `{transcript, answer_text, drawing_revision?, model, latency_ms, request_id}`. A silent recording returns `transcript: ""` and an "ask again" line without calling the language model.

### `POST /api/speak`

Request: `{"session_id": "any string", "text": "Take another look at line two.", "purpose": "hint"}`.

- `text`: 1 to 600 characters (not blank), else 422 `invalid_request`. Optional only for the two fixed announcements below.
- `purpose`: optional short lowercase label (`[a-z0-9_]{1,40}`, e.g. `hint`, `answer`, `check_ok`); it is logged, so free text is a 422.
- `purpose: "allowance_low"` and `"allowance_used_up"` are the fixed allowance announcements. The **server writes the sentence** ("You have about N minutes left this month." / "This month's tutoring hours are used up. Ask Edward for more time."); any `text` the client sends is ignored. They are allowed when the hours are used up; normal speech is then `403 hours_used_up`. This lets the tutor say the last words in its own voice without opening free text-to-speech to a code that is out of hours.
- Order of checks: code (401/403), POST (405), hours (403, announcements excepted), body (400/413/422), key or scripted mode (503).

**Response 200: a stream of raw PCM audio**, signed 16-bit little-endian, 24,000 Hz, mono, no header. `Content-Type: application/octet-stream`; headers `x-audio-format: pcm_s16le_24000`, `x-voice-provider: elevenlabs | openai | scripted`, `x-voice-fallback: <reason>` (only when ElevenLabs was skipped), `x-latency-ms` (server time to the first audio), `x-request-id`, `x-allowance-state`, `x-allowance-remaining-seconds`. ElevenLabs audio is relayed as it arrives (the server waits for the first chunk, so a refusal or an empty stream can still fall back); OpenAI audio is generated whole and sent in one piece. A chunk can end mid-sample (odd byte count); the client must carry the odd byte.

**The voice and its fallback.** 1. ElevenLabs: `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000` with `xi-api-key`, `model_id: eleven_v4_turbo`, `language_code: en`, `voice_settings: {stability, similarity_boost}`, a 6 s limit to the first audio and 45 s overall. 2. If that cannot start (no `ELEVENLABS_API_KEY`, HTTP error such as `elevenlabs_http_401_quota_exceeded`, timeout, empty stream), the same text goes to OpenAI text-to-speech with `outputFormat: "pcm"` and a warning line `voice_fallback` (`from`, `to`, `reason`) is logged. 3. If both fail the answer is JSON `{error:"model_error", reason}` (502, 504 on timeout), and the app uses the device voice. A failure after the audio has started is logged as `stream_failed`; the client keeps what it received. Provider messages are never copied into replies or logs, only labels.

**Characters are billed per character**, so each utterance's length is counted: the response line logs `text_chars`; `usage_months.tts_chars` is the student's running total for the month (and `tts_chars_eleven` the ElevenLabs part); a second line `stream_done` logs `audio_bytes`, `total_ms` and `tts_chars_month`. The text itself is never logged. A failed write of the count is logged as `chars_not_recorded` and never stops the audio. Scripted mode returns 0.1 s of silent PCM (4,800 bytes) with no key and no network.

Settings (Vercel env): `ELEVENLABS_API_KEY` (secret; without it every utterance goes to OpenAI), `ELEVENLABS_VOICE_ID` (production: Edward's clone "Edward Tutor" `9fNlRrOOvKvNtWqijXab`; code default Eric, the premade American male voice `cjVigY5qzO86Huf0OWal`), `ELEVENLABS_MODEL` (default `eleven_v4_turbo`), `ELEVENLABS_STABILITY` (0.5), `ELEVENLABS_SIMILARITY` (0.75). The OpenAI fallback: `SPEAK_MODEL` (default `gpt-4o-mini-tts`), `SPEAK_VOICE` (default `coral`), `SPEAK_INSTRUCTIONS` (default "Warm, patient math tutor talking to a 14-year-old. Calm, encouraging, natural pace. Say math aloud plainly."), using `OPENAI_API_KEY` through the AI SDK's `generateSpeech`. Sources: model id https://elevenlabs.io/docs/overview/models, streaming endpoint https://elevenlabs.io/docs/api-reference/text-to-speech/stream, price $0.04 per 1,000 characters https://elevenlabs.io/pricing/api (all read 2026-11-14).

### `POST /api/live-session`

The iPad makes a WebRTC offer; this endpoint creates the GPT-Live session with the project key and hands back the answer. OpenAI documents no ephemeral client secret for Live, so the server relays the SDP offer and answer ([connection guide](https://developers.openai.com/api/docs/guides/voice-webrtc?api=live)). The key never reaches the app.

Request: `{"session_id": "any string", "problem_id": "u3-04", "problem_text"?: "...", "sdp": "<the offer, starts with v=0, at most 64 KB>"}` (`problem_text` only with an `own:<course>` id, see Own problems).

Response 200: `{session_id, sdp, model, voice, latency_ms, request_id}`. `session_id` is OpenAI's Live session id and `sdp` is the answer to apply as the remote description. The app then uses the data channel `oai-events` (create it before the offer; do not send `session.start`).

The session it creates: `model` from `LIVE_MODEL` (default `gpt-live-1`), `audio.output.voice` from `LIVE_VOICE` (default `meridian`), `instructions` = `LIVE_TUTOR_INSTRUCTIONS` in `lib/policy.ts` plus the problem statement (never the worked solution), a developer greeting message, `delegation: {type: "client"}`, and `client.data_channel.allowed_client_events` = exactly `session.input_audio.mute`, `session.input_audio.unmute`, `session.thinking.append`, `session.commentary.append`, `session.close`.

Errors: 401 token, 405 method, 400/413 body, 422 invalid request (`sdp` missing, over 64 KB or not an SDP; unknown `problem_id`), 502 provider error (`reason` is `provider_http_<status>` and similar, never OpenAI's message), 504 provider timeout (15 s), 503 missing key, or scripted mode (it has no real session to give).

### `POST /api/consult`

GPT-Live cannot take images. When it delegates ("check my work"), the iPad captures the page and calls this endpoint over HTTPS; the report goes back to Live as `session.commentary.append`.

Request: `{session_id, problem_id, problem_text?, drawing_revision?, image_png_base64, question, recent}` (`problem_text` only with an `own:<course>` id, see Own problems). `question` is what the student just said (1 to 800 characters, from Live's own transcript). `recent` is up to 8 turns `{role: "student"|"tutor", text (at most 400)}`. Image rules are the same as `/api/watch`.

Response 200: `{answer_text, drawing_revision?, model, latency_ms, request_id}`. The answer says what is written, whether the latest step is right, wrong or unfinished, and one nudge; never the final answer (`CONSULT_POLICY` in `lib/policy.ts`). It uses the ask model (`ASK_MODEL`) through the same `runAskModel` as `/api/ask`. Scripted mode returns a fixed report.

### `GET /api/health`

`{ok, version, vercel_env, openai_key_present, gemini_key_present, database_configured, voice_provider ("elevenlabs" when a key is set, else "openai"), voice:{provider, elevenlabs:{key_present, model, voice_id, output_format}, fallback:["openai","device"]}, scripted, scripted_refused_in_production, models:{watch,ask,stt,speak,live}, models_advanced, live_voice, problems}`. No secrets, ever. It does not touch the database (an unauthenticated URL must not be able to keep it awake); `GET /api/me` proves it.

## Missing key and scripted mode

If the chosen provider's key is absent, watch and ask answer `503 {error:"missing_key", reason:"OPENAI_API_KEY is not set"}` (Gemini: `GEMINI_API_KEY is not set`; `GOOGLE_GENERATIVE_AI_API_KEY` is also accepted). The code is checked first, then the key, then the body, so an empty smoke call with a valid code sees the 503. `/api/speak` has its own key rule: it needs `ELEVENLABS_API_KEY` or `OPENAI_API_KEY` (503 `ELEVENLABS_API_KEY is not set` only when neither exists).

`TUTOR_SCRIPTED=1` (tests only) answers from a fixed script with no key and no network. It still validates the request. It refuses to turn on when `VERCEL_ENV` is `production`: the flag is ignored, an error line is logged, and `/api/health` reports `scripted_refused_in_production: true`.

The script, for the iPad UI test:

- `/api/watch`, `problem_id` `u3-04` (the planted-mistake problem): interrupts on line 2 when `lines` contains index 2 and `history` has no earlier interrupt on line 2. `hint_written` is "Check the signs here". Every other look waits.
- `/api/watch`, any other problem: always `wait` (the clean problem).
- `/api/ask`: `transcript: "scripted question"`, a fixed `answer_text`.

## Models and where the defaults come from

Provider and model are environment variables, set per role and per difficulty level. Checked against the vendors' own pages on
2026-11-13 and against the keys' model lists on 2026-11-14. `ask` is also what `/api/consult` uses.

Which row a problem uses is its **tier**: `standard` (the high school row, the cheap model) unless its course's `course.json` says
`"tier": "advanced"` or the problem's own `level` is `advanced` (`levelOf` in `lib/problems.ts`). The bank's `college` level does not
escalate: all 15 courses, calculus-1, linear-algebra and discrete-math included, are standard. The advanced model costs about ten times
more per look, so a course should move only after handwriting results for it are measured. Every request logs `course` and `tier`. An
own problem (typed by the student) takes `OWN_PROBLEM_LEVEL` instead, currently advanced. The
level picks which set of variables applies:

| variable (high school) | default (openai) | default (google) | advanced: variable and default (openai) |
|---|---|---|---|
| `WATCH_PROVIDER` / `WATCH_MODEL` / `WATCH_EFFORT` | `openai` / `gpt-6-luna` / provider default | `gemini-4-argon` | `WATCH_PROVIDER_ADVANCED` / `WATCH_MODEL_ADVANCED` / `WATCH_EFFORT_ADVANCED`: `gpt-6.1-sol` |
| `ASK_PROVIDER` / `ASK_MODEL` / `ASK_EFFORT` | `openai` / `gpt-6-luna` / provider default | `gemini-3.8-flash` | `ASK_PROVIDER_ADVANCED` / `ASK_MODEL_ADVANCED` / `ASK_EFFORT_ADVANCED`: `gpt-6.1-sol` |
| `STT_MODEL` | `gpt-transcribe` | `gemini-3.5-transcribe` | same for both levels |

`*_EFFORT` is `none`, `low`, `medium` or `high` (OpenAI `reasoningEffort`; Google `thinkingLevel`, `none` meaning `minimal`); a bad value
is a 503 `bad_config`. `/api/health` shows `models` (high school, with an effort if set) and `models_advanced`. The advanced route was
not evaluated on handwritten calculus or linear algebra pages; only the high school route has an eval.

The course also sets how the tutor talks (`audienceFor` in `lib/policy.ts`): every watch, ask, consult and live prompt starts with
`Course: <title>. The student is <who>. <vocabulary>` (grade 5 to 7: "a Grade N student ... about N+5 or N+6 years old", short sentences,
simple everyday words, explain a math word the first time; grade 8 to 12: "a Grade N student in British Columbia", the words of that course;
college: "a first-year college or university student", the standard terms). A problem with no course keeps the original Grade 9 tutor.

Why `gpt-6-luna` for high school (plan amendment 14): 30 synthetic pages, 2 repetitions, through the real handlers. Luna matched
`gpt-6.1-sol` on first-wrong-line accuracy (30/30 each, watch and consult), had 0 false alarms and 0 schema failures, and cost about
$0.00016 a watch look against $0.00243, and $0.00022 a consult look against $0.00315 (estimated from the price table). Table and
caveats: `docs/plan.md` amendment 14; raw rows: `eval/results/main2.jsonl`. The pages are fonts with jitter, not real handwriting.

`STT_MODEL` unset follows `ASK_PROVIDER`. `STT_MODEL` set: a name starting with `gemini` uses Google, anything else OpenAI.

Capability proof, per default:

- `gpt-6.1-sol`: Input "Text, Image", structured outputs supported. https://developers.openai.com/api/docs/models/gpt-6.1-sol
- `gpt-6.1-terra`: Input "Text, Image". https://developers.openai.com/api/docs/models/gpt-6.1-terra
- `gpt-transcribe`: Input "Audio, Text", endpoint `v1/audio/transcriptions`. https://developers.openai.com/api/docs/models/gpt-transcribe
- `gemini-4-argon`: Inputs "Text, Image, Video, Audio, and PDF", structured outputs supported. https://ai.google.dev/gemini-api/docs/models/gemini-4-argon
- `gemini-3.8-flash`: Inputs "Text, Image, Video, Audio, and PDF", structured outputs supported. https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
- `gemini-3.5-transcribe`: Inputs "Audio (up to 1 hour)". https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe
- OpenAI model list (all latest models take text and image): https://developers.openai.com/api/docs/models
- AI SDK structured output (`generateText` + `Output.object`): https://ai-sdk.dev/docs/ai-sdk-core/generating-structured-data ; transcription (`transcribe`): https://ai-sdk.dev/docs/ai-sdk-core/transcription

- `gpt-live-1`: Input "Audio, Text", Output "Audio, Text", image not supported, $0.05 per minute of session, endpoint `v1/live/sessions`, 50 concurrent sessions on the Build tier. https://developers.openai.com/api/docs/models/gpt-live-1
- `gpt-4o-mini-tts` (the fallback voice): Deprecated, shutdown Jan 6, 2027, notice Oct 1, 2026. https://developers.openai.com/api/docs/deprecations

Also checked: `gpt-6-luna` takes text and image (cheaper, an option for ask). `gpt-6-astra` is listed at $10/$50 per million tokens, not used by default. `gpt-realtime-2.1` was not verified and is not used (this path is request and response, not a live session).

Latency (eval, 1024 x 544 page, median / p90): gpt-6-luna watch 2.5 s / 3.3 s, consult 4.4 s / 6.1 s; gpt-6.1-sol watch 3.1 s / 4.2 s. To go
back to the earlier models without a code change: `WATCH_MODEL=gpt-6.1-sol` and `ASK_MODEL=gpt-6.1-terra`. If Luna interrupts on lines still
being written in real use, `WATCH_MODEL=gpt-6.1-terra` (same accuracy in the eval, about 8 times Luna's cost).

## Watch policy

`lib/policy.ts` (`WATCH_POLICY`), adapted from `tutor-timing-test/tt.py`: waiting is the default; interrupt only for a clear, consequential wrong step on a finished line; an unfinished line or a pause is not a reason; crossed-out work is a self-correction; hint, never the answer; compare with the reference worked solution but accept any valid method; name the line by its margin number. Output is a Zod schema through `generateText` + `Output.object`, then re-validated in `lib/decision.ts`.

## Student memory (opt-in)

Off for everyone. Nothing is remembered about a code until the latest `consent_events` row is a grant of the current consent text (`lib/record/notice.ts`, version `NOTICE_VERSION`), recorded either by a parent or guardian, or an adult student, in the app (`POST /api/memory`, a checkbox attestation, no names) or by Edward from a signed form (`scripts/codes consent`). A new text version means asking again. Full design: `docs/tutor-memory-plan.md`; draft policy: `docs/privacy-policy.md` (served at `/api/privacy`, a copy in `lib/record/policy-text.ts`, refresh with `npm run sync-policy`). Not legal advice.

- **Switches (server env).** `STUDENT_RECORD=on`: record looks and questions, read notes, accept new agreements. Unset: none of that happens and `POST consent` answers 404; managing an existing record (`GET`, withdraw, erase) always works. `STUDENT_RECORD_REWORD=on` (only with the first): the spoken hint may be reworded with Edward's notes. Default off; it is the part with open review objections.
- **Tables** (migration `004_student_memory.sql`): `consent_events` (append-only), `human_note` (Edward only), `attempt` (looks and questions per student, session, problem), `hint_event` (one per interrupt: a line number and a revision, no hint text). No names, pictures, audio, transcripts or hint text.
- **Watch path.** The watch call runs exactly as without memory and decides first. Afterwards one statement records the look (consent is checked inside it) and, for an interrupt by a student who agreed, returns up to 3 notes. With the reword switch on, a second text-only call (no picture, no solution) may reword the **spoken** hint only; the written hint, the line and the decision are untouched. Any problem (timeout, parse failure, the final answer in the text, recall phrasing such as "last time") keeps the original spoken hint. Logs: `memory_write` (`ok | skipped:no_consent | failed:<code>`), `memory_notes`, `reword` (`used | fallback:<reason>`), `reword_*` tokens and cost; lifecycle lines `memory_consent_granted`, `memory_withdrawn`, `memory_erased`. Never logged: notes, hints, codes.
- **`/api/ask` and `/api/consult`** only count one question for a student who agreed.
- **Endpoint.** `GET /api/memory`: `{feature, notice:{version,title,intro,sections,policy_url}, consent:{granted,current,given_by,recorded_via,notice_version,at}, record:{notes,recent:[{problem_id,looks,asks,interrupts,last_at}]}}`; `feature:"off"` alone when the switch is off and nothing is on record. `POST`: `{action:"consent",given_by:"parent_guardian"|"adult_student",notice_version,attested:true}` (422 without the attestation, 409 on an old text, 404 when the switch is off), `{action:"withdraw",erase:boolean}`, `{action:"erase"}`.
- **Erase** is one statement (withdrawal plus delete). A write already in flight can leave a late row; run `scripts/codes forget CODE --yes` again. Not race-free (plan section 12).
- **Tests.** `test/record.test.ts` (handlers with stubs: detection unchanged across consecutive looks, fallbacks, endpoints, the notice pinned by hash, the policy page). `test/record.pglite.test.ts` runs the real SQL on PGlite (Postgres compiled to WebAssembly) on CI; on a laptop only with `PT_PGLITE=1`. `eval/run-reword.ts` measures the rewrite on the wrong-work fixtures (needs an OpenAI key in the environment; see the plan, section 9).

## Logging

One JSON line per request on stdout (Vercel runtime logs): `request_id, endpoint, method, provider, model, level, `course` (the course slug, or `none`), `tier` (`standard` or `advanced`; watch, ask, consult), effort (when set), latency_ms, model_ms, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, est_cost_usd, cost_basis, image_bytes, line_count, drawing_revision, history_in, history_used, action, line, status, outcome, reason` (a label such as `model_wait`, `malformed_output`, `line_not_in_page`, `hint_reveals_answer`, `unauthorized:bad_token`, `missing_key`). Successes are logged too. Never logged: images, audio, transcripts, hints, spoken text, reasons, tokens, keys (only sizes and counts). Every request that reaches the code check also logs `student` (the 8-character hash of the code, never the code), `db_queries` and `db_ms` (time waiting on the database), `allowance_state`, `used_seconds` and `cap_seconds`; a counted request adds `counted_kind`, `remaining_minutes` and `allowance_notice`. Outcomes include `unauthorized:unknown_code`, `unauthorized:malformed_code`, `code_disabled`, `hours_used_up`, `live_not_in_plan`, `database_unavailable:<db_label>`; failures to count are `meter_failed`. `/api/speak` logs `text_chars, purpose, provider, model, voice_id, audio_format, latency_ms, first_audio_ms` when the audio starts, then `stream_done` with `audio_bytes, total_ms, tts_chars_month` (or `stream_failed`, `stream_cancelled`), and `voice_fallback` (warning: `from`, `to`, `reason`) when ElevenLabs was skipped. `/api/live-session` logs `sdp_chars, answer_sdp_chars, live_session, voice, model, latency_ms`. `/api/consult` logs `image_bytes, question_chars, recent_turns, answer_chars`. Every model endpoint and `live-session` also logs `problem_kind` (`bank` or `own`), `course`, `tier` and, for an own problem, `problem_text_chars` (a count, never the text); a refused own problem logs outcome `unknown_course` or `invalid_request`. Neither logs the offer, the answer, the words or any key.

## Files

- `api/*.ts` thin Vercel entry points. `lib/` the logic: `gate.ts` (code check, plan, hours, key, scripted; `meterActivity` counts a request), `students.ts` (code alphabet, the counting rule `chargeFor`, `allowanceOf`, the server's SQL in `PgStudentStore`), `students-memory.ts` (the same rules in memory, for tests), `students-admin.ts` (the admin script's SQL and the migration runner), `db.ts` (the one door to Postgres), `voice.ts` (the ElevenLabs stream; tests pass a fake `VoiceGateway`), `speak.ts`, `me.ts`, `heartbeat.ts`, `watch.ts`, `ask.ts`, `consult.ts`, `live.ts` (the one place that talks to OpenAI's Live endpoint; tests pass a fake `LiveGateway`), `models.ts` (AI SDK calls), `policy.ts`, `decision.ts`, `image.ts`, `config.ts`, `log.ts`, `http.ts`, `health.ts`.
- `db/migrations/*.sql` additive migrations (`001_students.sql`, `002_last_activity_at.sql`, `004_student_memory.sql`); `scripts/codes migrate` applies them (idempotent). `scripts/` Edward's local tools: `codes` (admin), `clone-voice`, `set-elevenlabs-key`, `live-check`; none run on the server.
- `test/db.integration.test.ts` runs the real SQL against the real database and is OFF unless `PT_DB_INTEGRATION=1` and `DATABASE_URL` are set (it makes and deletes its own test codes); CI skips it. Run it with `PT_DB_INTEGRATION=1 vercel env run -e production -- npx tsx --test test/db.integration.test.ts`.
- `data/problems.json` is GENERATED from `../shared/` (the original 12 plus every `shared/courses/<slug>/problems.json`) because `vercel deploy` uploads only `server/`. It holds `courses` (slug, title, group, grade, level) and `problems` (id, course, prompt_plain, worked_solution, final_answer, level), 1,024 problems and about 430 KB at 15 courses. Refresh with `npm run build-courses` (also writes `shared/courses/index.json`, the manifest the iPad reads); `scripts/build-courses.ts` validates every file and fails on a duplicate id across all courses. A test fails when either generated file is stale. A new course folder needs no code change, only that command and a deploy.
- `lib/pricing.ts` the price table (USD per million tokens, sources and fetch date in the file; dated Google increases switch on their day) and `lib/usage.ts` (counts to a log report). An unknown model logs `cost_basis: "no_price"` and no dollar figure; a model that reports no usage logs `no_usage`.
- `eval/` the model eval, run by hand (not CI): `make_fixtures.py` (30 synthetic pages into `eval/fixtures/`, committed), `run-eval.ts` (drives the real `handleWatch` and `handleConsult`), `score.ts` (table), `results/` (committed runs). How to run it: `docs/how-to-run.md`.
- `test/` Node's test runner via `tsx`: `npm test`. Typecheck: `npm run typecheck` (CI runs both, `.github/workflows/server.yml`).

## Deploy

Vercel project `pencil-tutor`, scope `edwards-projects-7fd27381`. From `server/`: `vercel deploy --prod --scope edwards-projects-7fd27381`. Set these in the Vercel dashboard or with `vercel env add` (never committed): `DATABASE_URL` (set by the Neon integration; do not edit), `ELEVENLABS_API_KEY` (`scripts/set-elevenlabs-key`), `ELEVENLABS_VOICE_ID`, `OPENAI_API_KEY` and/or `GEMINI_API_KEY`, optionally `ELEVENLABS_MODEL`, `ELEVENLABS_STABILITY`, `ELEVENLABS_SIMILARITY`, `WATCH_PROVIDER`, `WATCH_MODEL`, `ASK_PROVIDER`, `ASK_MODEL`, `STT_MODEL`, `SPEAK_MODEL`, `SPEAK_VOICE`, `SPEAK_INSTRUCTIONS`, `LIVE_MODEL`, `LIVE_VOICE` (Live uses the same `OPENAI_API_KEY`). Do not set `TUTOR_SCRIPTED` on the production environment.

## Problem banks: `shared/problems.json` and `shared/courses/<slug>/`

One folder per course under `shared/courses/` holds `problems.json` (same fields as below) and a README. An optional `course.json`
(`{ "title": "BC Math 5", "group": "elementary", "grade": 5, "tier": "standard" }`; `tier` is `standard` (default, the cheap model) or `advanced` (the frontier model, about ten times the cost; only after handwriting results are measured); `group` is `elementary`, `high_school` or `college`; `grade` is
`null` for college) sets how the picker shows it. Without one, `build-courses` works the title out from the folder name
(`bc-fmpc-10` becomes "BC Foundations of Math and Pre-calculus 10"), the grade from the trailing number and the group from the grade
(7 and below elementary) or a `college` level, and prints a note. The original 12 problems stay in `shared/problems.json` and are
listed as one more course, `bc-math-9-unit-3`, so older app builds that send `u3-..` ids keep working.

`shared/problems.json` is a JSON array of 12 equation problems from BC Math 9 unit 3, each paired by hand with its worked solution (every pairing re-solved; `test/problems.test.ts` substitutes each final answer back into its prompt). Fields:

| field | meaning |
|---|---|
| `id` | `u3-NN`, NN is the problem number in `extra-practice.md` |
| `source` | where it came from, for humans |
| `prompt_latex` | the original LaTeX (not rendered on device) |
| `prompt_plain` | readable one-line text, e.g. `2k/5 − 3 = 1` (real minus sign U+2212) |
| `prompt_parts` | what the iPad draws, left to right |
| `worked_solution` | array of plain-text lines, one step each |
| `final_answer` | e.g. `k = 10` |

`prompt_parts` is a list of items, each exactly one of:

- `{ "text": "7x − 4 = 3x + 16" }` draw as ordinary text
- `{ "frac": { "num": "2k", "den": "5" } }` draw as a stacked fraction (numerator over a bar over denominator)

Draw the parts in order on one baseline-aligned row. Example, `(2/3)(x − 1) = (1/2)(x + 3)`:
`frac(2,3)`, text `(x − 1) = `, `frac(1,2)`, text `(x + 3)`. Numerator and denominator are plain text and may contain spaces and operators (`x + 4`). Fractions never nest.

The iPad needs only `id`, `prompt_plain` and `prompt_parts`. `worked_solution` and `final_answer` are the tutor's reference and should not ship readable in the app (the server loads its own copy of this file).
