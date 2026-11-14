# Pencil Tutor server

Vercel Functions in TypeScript, no framework. Eight endpoints. **The base plan (plan amendment 13):** tap-to-talk, every utterance in ElevenLabs Eleven v4 Turbo streamed from `/api/speak` (falling back to OpenAI text-to-speech, then the device voice), one code per student, an 8-hour monthly cap. The only storage is a Neon Postgres database (Vercel Marketplace, Free plan) holding student codes and monthly usage. GPT-Live-1 (`/api/live-session`, `/api/consult`) is a premium option reachable only when the student's plan has `live: true` (`docs/live-voice-plan.md`).

| endpoint | auth | purpose |
|---|---|---|
| `GET /api/health` | none | version, which keys exist (yes/no), configured models, the voice provider, whether the database is configured |
| `GET /api/me` | code | checks a code; returns the plan and the month's allowance; free (not counted as activity) |
| `POST /api/heartbeat` | code | "a problem is open and the student was active in the last 2 minutes"; counts the time; returns the allowance |
| `POST /api/watch` | code | page picture in, `wait` or `interrupt` out; counted as activity |
| `POST /api/ask` | code | spoken question (m4a) + page picture in, transcript + answer text out; counted as activity |
| `POST /api/speak` | code | text in, a stream of PCM audio out: ElevenLabs, else OpenAI (`gpt-4o-mini-tts` is deprecated, shutdown 2027-01-06) |
| `POST /api/live-session` | code, plan.live | the iPad's WebRTC offer in, GPT-Live-1's answer out (the OpenAI key stays here) |
| `POST /api/consult` | code | the page reader GPT-Live delegates to: the student's words and a page picture in, report text out; counted as activity |

Every endpoint except health needs `Authorization: Bearer <CODE>`, where CODE is the student's 8-character code (see Student codes and the monthly cap below). **The code replaces the old shared `APP_ACCESS_TOKEN`, which the server no longer reads.** Anything that is not a well-formed code is `401 {error:"unauthorized", reason:"missing_header" | "bad_scheme" | "malformed_code"}`; a well-formed code nobody has is `401 … "unknown_code"`; a turned-off code is `403 code_disabled`. The order of checks: code present and well formed (401), method (405), the code exists and is on (401/403, one database query), the plan allows it (403 `live_not_in_plan`), the month's hours are not used up (403 `hours_used_up`), configuration (503), key or scripted mode (503), then the body.

## Student codes and the monthly cap

**Codes.** 8 characters from `ABCDEFGHJKMNPQRSTVWXYZ23456789` (30 symbols; no I, L, O, U, 0, 1), generated with `crypto.randomInt`; 30^8 is about 6.6e11. Stored in `students` with `monthly_cap_seconds` (default 28800 = 8 hours), `plan_live` (default false) and `disabled_at`. No name or any other personal field exists. Logs carry only `student`, an 8-character salted SHA-256 prefix of the code (`scripts/codes list` prints it as "log id"). Admin: `scripts/codes` (`docs/how-to-run.md`).

**What counts.** A counted minute is a minute with a problem open and recent activity: ink, a question or a look within the last 2 minutes. Each activity event keeps the meter running for 120 seconds after it. Counted time is the length of the union of those windows: an event is charged only the part of its 120 seconds that an earlier event did not already cover (`chargeFor` in `lib/students.ts`; the same rule is one SQL statement, `CHARGE_SQL`, checked against it by `test/db.integration.test.ts`). Counted as activity: a valid `/api/watch` (a look), `/api/ask` and `/api/consult` (questions), `/api/live-session` (opening live) and `/api/heartbeat`. Not counted: `/api/me`, `/api/speak`, `/api/health`, and any request refused before its body is valid. The app sends a heartbeat every 60 seconds only while a problem is open and there was ink, a question or a look in the last 2 minutes, so thinking time and long lines are covered; time with no activity is not. The first event of a month is charged a full 120 seconds.

**The month.** `usage_months` has one row per student per month; the month is the first day of the month in America/Vancouver (`vancouverMonth`; the offset comes from the runtime's time-zone database). It resets on the 1st. `counted_seconds` is a running total that is only ever incremented. A top-up (`scripts/codes topup`) adds `bonus_seconds` to the current month's row only.

**The allowance object.** Returned in `/api/me`, `/api/heartbeat`, `/api/watch`, `/api/ask`, `/api/consult`, `/api/live-session` bodies and in the bodies of the 403s:

```json
{ "month": "2026-11", "used_seconds": 120, "cap_seconds": 28800, "remaining_seconds": 28680, "remaining_minutes": 478,
  "percent_used": 0.4, "state": "ok", "notice": null }
```

`state` is `ok` below 80% used, `low` from 80%, `used_up` at 100%. `notice` is `"low"` on exactly one response per month (the one during which 80% was crossed) and `"used_up"` on exactly one (the one during which 100% was crossed), otherwise null; a single jump from ok to used up sends only `used_up`. Each is claimed atomically in the database (`low_notice_at`, `used_up_notice_at`), and a top-up re-arms them. `/api/speak` carries `x-allowance-state` and `x-allowance-remaining-seconds` headers instead. When the hours are used up, `watch`, `ask`, `consult`, `heartbeat`, `live-session` and normal `speak` answer `403 {error:"hours_used_up", allowance}` and count nothing; `/api/me` and the two fixed announcements below still answer. Concurrent requests can overshoot the cap by one window (about 2 minutes). If counting fails after the checks passed, the request is still served and an error line `meter_failed` is logged; if the code lookup fails the answer is `503 database_unavailable` and the app keeps its stored code.

**`GET /api/me`** returns `{plan:{live:boolean, cap_minutes:number}, allowance, request_id}`. The app calls it when a code is typed (that is how a code is checked), at launch and when a problem opens (which also wakes the sleeping database).

**`POST /api/heartbeat`** takes `{session_id?, problem_id}` (`problem_id` must be in the bank) and returns `{ok:true, allowance, request_id}`.

## Contract

All bodies are JSON. Error bodies are `{error, reason, request_id}`. Every response carries `request_id` and an `x-request-id` header.

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

- `problem_id`: exactly one id from `shared/problems.json`. Unknown or a list: 422.
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

`drawing_revision` is optional here (echoed if sent). Audio over 2.5 MB: 422 `invalid_audio`. Response 200: `{transcript, answer_text, drawing_revision?, model, latency_ms, request_id}`. A silent recording returns `transcript: ""` and an "ask again" line without calling the language model.

### `POST /api/speak`

Request: `{"session_id": "any string", "text": "Take another look at line two.", "purpose": "hint"}`.

- `text`: 1 to 600 characters (not blank), else 422 `invalid_request`. Optional only for the two fixed announcements below.
- `purpose`: optional short lowercase label (`[a-z0-9_]{1,40}`, e.g. `hint`, `answer`, `check_ok`); it is logged, so free text is a 422.
- `purpose: "allowance_low"` and `"allowance_used_up"` are the fixed allowance announcements. The **server writes the sentence** ("You have about N minutes left this month." / "This month's tutoring hours are used up. Ask Edward for more time."); any `text` the client sends is ignored. They are allowed when the hours are used up; normal speech is then `403 hours_used_up`. This lets the tutor say the last words in its own voice without opening free text-to-speech to a code that is out of hours.
- Order of checks: code (401/403), POST (405), hours (403, announcements excepted), body (400/413/422), key or scripted mode (503).

**Response 200: a stream of raw PCM audio**, signed 16-bit little-endian, 24,000 Hz, mono, no header. `Content-Type: application/octet-stream`; headers `x-audio-format: pcm_s16le_24000`, `x-voice-provider: elevenlabs | openai | scripted`, `x-voice-fallback: <reason>` (only when ElevenLabs was skipped), `x-latency-ms` (server time to the first audio), `x-request-id`, `x-allowance-state`, `x-allowance-remaining-seconds`. ElevenLabs audio is relayed as it arrives (the server waits for the first chunk, so a refusal or an empty stream can still fall back); OpenAI audio is generated whole and sent in one piece. A chunk can end mid-sample (odd byte count); the client must carry the odd byte.

**The voice and its fallback.** 1. ElevenLabs: `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000` with `xi-api-key`, `model_id: eleven_v4_turbo`, `language_code: en`, `voice_settings: {stability, similarity_boost}`, a 6 s limit to the first audio and 45 s overall. 2. If that cannot start (no `ELEVENLABS_API_KEY`, HTTP error such as `elevenlabs_http_401_quota_exceeded`, timeout, empty stream), the same text goes to OpenAI text-to-speech with `outputFormat: "pcm"` and a warning line `voice_fallback` (`from`, `to`, `reason`) is logged. 3. If both fail the answer is JSON `{error:"model_error", reason}` (502, 504 on timeout), and the app uses the device voice. A failure after the audio has started is logged as `stream_failed`; the client keeps what it received. Provider messages are never copied into replies or logs, only labels.

**Characters are billed per character**, so each utterance's length is counted: the response line logs `text_chars`; `usage_months.tts_chars` is the student's running total for the month (and `tts_chars_eleven` the ElevenLabs part); a second line `stream_done` logs `audio_bytes`, `total_ms` and `tts_chars_month`. The text itself is never logged. A failed write of the count is logged as `chars_not_recorded` and never stops the audio. Scripted mode returns 0.1 s of silent PCM (4,800 bytes) with no key and no network.

Settings (Vercel env): `ELEVENLABS_API_KEY` (secret; without it every utterance goes to OpenAI), `ELEVENLABS_VOICE_ID` (default Eric, the premade American male voice `cjVigY5qzO86Huf0OWal`), `ELEVENLABS_MODEL` (default `eleven_v4_turbo`), `ELEVENLABS_STABILITY` (0.5), `ELEVENLABS_SIMILARITY` (0.75). The OpenAI fallback: `SPEAK_MODEL` (default `gpt-4o-mini-tts`), `SPEAK_VOICE` (default `coral`), `SPEAK_INSTRUCTIONS` (default "Warm, patient math tutor talking to a 14-year-old. Calm, encouraging, natural pace. Say math aloud plainly."), using `OPENAI_API_KEY` through the AI SDK's `generateSpeech`. Sources: model id https://elevenlabs.io/docs/overview/models, streaming endpoint https://elevenlabs.io/docs/api-reference/text-to-speech/stream, price $0.04 per 1,000 characters https://elevenlabs.io/pricing/api (all read 2026-11-14).

### `POST /api/live-session`

The iPad makes a WebRTC offer; this endpoint creates the GPT-Live session with the project key and hands back the answer. OpenAI documents no ephemeral client secret for Live, so the server relays the SDP offer and answer ([connection guide](https://developers.openai.com/api/docs/guides/voice-webrtc?api=live)). The key never reaches the app.

Request: `{"session_id": "any string", "problem_id": "u3-04", "sdp": "<the offer, starts with v=0, at most 64 KB>"}`.

Response 200: `{session_id, sdp, model, voice, latency_ms, request_id}`. `session_id` is OpenAI's Live session id and `sdp` is the answer to apply as the remote description. The app then uses the data channel `oai-events` (create it before the offer; do not send `session.start`).

The session it creates: `model` from `LIVE_MODEL` (default `gpt-live-1`), `audio.output.voice` from `LIVE_VOICE` (default `meridian`), `instructions` = `LIVE_TUTOR_INSTRUCTIONS` in `lib/policy.ts` plus the problem statement (never the worked solution), a developer greeting message, `delegation: {type: "client"}`, and `client.data_channel.allowed_client_events` = exactly `session.input_audio.mute`, `session.input_audio.unmute`, `session.thinking.append`, `session.commentary.append`, `session.close`.

Errors: 401 token, 405 method, 400/413 body, 422 invalid request (`sdp` missing, over 64 KB or not an SDP; unknown `problem_id`), 502 provider error (`reason` is `provider_http_<status>` and similar, never OpenAI's message), 504 provider timeout (15 s), 503 missing key, or scripted mode (it has no real session to give).

### `POST /api/consult`

GPT-Live cannot take images. When it delegates ("check my work"), the iPad captures the page and calls this endpoint over HTTPS; the report goes back to Live as `session.commentary.append`.

Request: `{session_id, problem_id, drawing_revision?, image_png_base64, question, recent}`. `question` is what the student just said (1 to 800 characters, from Live's own transcript). `recent` is up to 8 turns `{role: "student"|"tutor", text (at most 400)}`. Image rules are the same as `/api/watch`.

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

A problem has a `level` in `shared/problems.json` (`high_school` when missing; every bank problem is `high_school`). The level picks
which set of variables applies:

| variable (high school) | default (openai) | default (google) | advanced: variable and default (openai) |
|---|---|---|---|
| `WATCH_PROVIDER` / `WATCH_MODEL` / `WATCH_EFFORT` | `openai` / `gpt-6-luna` / provider default | `gemini-4-argon` | `WATCH_PROVIDER_ADVANCED` / `WATCH_MODEL_ADVANCED` / `WATCH_EFFORT_ADVANCED`: `gpt-6.1-sol` |
| `ASK_PROVIDER` / `ASK_MODEL` / `ASK_EFFORT` | `openai` / `gpt-6-luna` / provider default | `gemini-3.8-flash` | `ASK_PROVIDER_ADVANCED` / `ASK_MODEL_ADVANCED` / `ASK_EFFORT_ADVANCED`: `gpt-6.1-sol` |
| `STT_MODEL` | `gpt-transcribe` | `gemini-3.5-transcribe` | same for both levels |

`*_EFFORT` is `none`, `low`, `medium` or `high` (OpenAI `reasoningEffort`; Google `thinkingLevel`, `none` meaning `minimal`); a bad value
is a 503 `bad_config`. `/api/health` shows `models` (high school, with an effort if set) and `models_advanced`. The advanced route has no
problems on it yet and was not evaluated.

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

## Logging

One JSON line per request on stdout (Vercel runtime logs): `request_id, endpoint, method, provider, model, level, effort (when set), latency_ms, model_ms, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, est_cost_usd, cost_basis, image_bytes, line_count, drawing_revision, history_in, history_used, action, line, status, outcome, reason` (a label such as `model_wait`, `malformed_output`, `line_not_in_page`, `hint_reveals_answer`, `unauthorized:bad_token`, `missing_key`). Successes are logged too. Never logged: images, audio, transcripts, hints, spoken text, reasons, tokens, keys (only sizes and counts). Every request that reaches the code check also logs `student` (the 8-character hash of the code, never the code), `db_queries` and `db_ms` (time waiting on the database), `allowance_state`, `used_seconds` and `cap_seconds`; a counted request adds `counted_kind`, `remaining_minutes` and `allowance_notice`. Outcomes include `unauthorized:unknown_code`, `unauthorized:malformed_code`, `code_disabled`, `hours_used_up`, `live_not_in_plan`, `database_unavailable:<db_label>`; failures to count are `meter_failed`. `/api/speak` logs `text_chars, purpose, provider, model, voice_id, audio_format, latency_ms, first_audio_ms` when the audio starts, then `stream_done` with `audio_bytes, total_ms, tts_chars_month` (or `stream_failed`, `stream_cancelled`), and `voice_fallback` (warning: `from`, `to`, `reason`) when ElevenLabs was skipped. `/api/live-session` logs `sdp_chars, answer_sdp_chars, live_session, voice, model, latency_ms`. `/api/consult` logs `image_bytes, question_chars, recent_turns, answer_chars`. Neither logs the offer, the answer, the words or any key.

## Files

- `api/*.ts` thin Vercel entry points. `lib/` the logic: `gate.ts` (code check, plan, hours, key, scripted; `meterActivity` counts a request), `students.ts` (code alphabet, the counting rule `chargeFor`, `allowanceOf`, the server's SQL in `PgStudentStore`), `students-memory.ts` (the same rules in memory, for tests), `students-admin.ts` (the admin script's SQL and the migration runner), `db.ts` (the one door to Postgres), `voice.ts` (the ElevenLabs stream; tests pass a fake `VoiceGateway`), `speak.ts`, `me.ts`, `heartbeat.ts`, `watch.ts`, `ask.ts`, `consult.ts`, `live.ts` (the one place that talks to OpenAI's Live endpoint; tests pass a fake `LiveGateway`), `models.ts` (AI SDK calls), `policy.ts`, `decision.ts`, `image.ts`, `config.ts`, `log.ts`, `http.ts`, `health.ts`.
- `db/migrations/*.sql` additive migrations (`001_students.sql`); `scripts/codes migrate` applies them (idempotent). `scripts/` Edward's local tools: `codes` (admin), `clone-voice`, `set-elevenlabs-key`, `live-check`; none run on the server.
- `test/db.integration.test.ts` runs the real SQL against the real database and is OFF unless `PT_DB_INTEGRATION=1` and `DATABASE_URL` are set (it makes and deletes its own test codes); CI skips it. Run it with `PT_DB_INTEGRATION=1 vercel env run -e production -- npx tsx --test test/db.integration.test.ts`.
- `data/problems.json` is a copy of `../shared/problems.json` because `vercel deploy` uploads only `server/`. A test fails if they differ. Refresh with `npm run sync-problems`.
- `lib/pricing.ts` the price table (USD per million tokens, sources and fetch date in the file; dated Google increases switch on their day) and `lib/usage.ts` (counts to a log report). An unknown model logs `cost_basis: "no_price"` and no dollar figure; a model that reports no usage logs `no_usage`.
- `eval/` the model eval, run by hand (not CI): `make_fixtures.py` (30 synthetic pages into `eval/fixtures/`, committed), `run-eval.ts` (drives the real `handleWatch` and `handleConsult`), `score.ts` (table), `results/` (committed runs). How to run it: `docs/how-to-run.md`.
- `test/` Node's test runner via `tsx`: `npm test`. Typecheck: `npm run typecheck` (CI runs both, `.github/workflows/server.yml`).

## Deploy

Vercel project `pencil-tutor`, scope `edwards-projects-7fd27381`. From `server/`: `vercel deploy --prod --scope edwards-projects-7fd27381`. Set these in the Vercel dashboard or with `vercel env add` (never committed): `DATABASE_URL` (set by the Neon integration; do not edit), `ELEVENLABS_API_KEY` (`scripts/set-elevenlabs-key`), `ELEVENLABS_VOICE_ID`, `OPENAI_API_KEY` and/or `GEMINI_API_KEY`, optionally `ELEVENLABS_MODEL`, `ELEVENLABS_STABILITY`, `ELEVENLABS_SIMILARITY`, `WATCH_PROVIDER`, `WATCH_MODEL`, `ASK_PROVIDER`, `ASK_MODEL`, `STT_MODEL`, `SPEAK_MODEL`, `SPEAK_VOICE`, `SPEAK_INSTRUCTIONS`, `LIVE_MODEL`, `LIVE_VOICE` (Live uses the same `OPENAI_API_KEY`). Do not set `TUTOR_SCRIPTED` on the production environment.

## Problem bank: `shared/problems.json`

A JSON array of 12 equation problems from BC Math 9 unit 3, each paired by hand with its worked solution (every pairing re-solved; `test/problems.test.ts` substitutes each final answer back into its prompt). Fields:

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
