# Pencil Tutor server

Vercel Functions in TypeScript, no framework, no database, no storage. Four endpoints. The iPad's voice is OpenAI text-to-speech from `/api/speak`; the device synthesizer is only its fallback (plan amendment 11).

| endpoint | auth | purpose |
|---|---|---|
| `GET /api/health` | none | version, which keys exist (yes/no), configured models |
| `POST /api/watch` | bearer | page picture in, `wait` or `interrupt` out |
| `POST /api/ask` | bearer | spoken question (m4a) + page picture in, transcript + answer text out |
| `POST /api/speak` | bearer | text in, mp3 audio out |

Every endpoint except health needs `Authorization: Bearer <APP_ACCESS_TOKEN>`. Anything else is `401 {error:"unauthorized"}`, including when the server has no token configured yet.

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
  "model": "gpt-6.1-sol",
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

- `text`: 1 to 600 characters (not blank), else 422 `invalid_request`.
- `purpose`: optional short lowercase label (`[a-z0-9_]{1,40}`, e.g. `hint`, `answer`, `check_ok`); it is logged, so free text is a 422.
- Order of checks is the same as `/api/ask`: token (401), POST (405), key or scripted mode (503), body (400/413/422).

Response 200: the raw mp3 bytes, `Content-Type: audio/mpeg`, headers `X-Latency-Ms` (server time) and `x-request-id`. Errors are the usual JSON `{error, reason, request_id}`: 502 provider error, 504 provider timeout, 503 missing key. Scripted mode returns a fixed 1668-byte silent mp3 (4 valid MPEG frames) with no key and no network.

Settings (Vercel env, all optional): `SPEAK_MODEL` (default `gpt-4o-mini-tts`), `SPEAK_VOICE` (default `coral`), `SPEAK_INSTRUCTIONS` (default "Warm, patient math tutor talking to a 14-year-old. Calm, encouraging, natural pace. Say math aloud plainly."). Speech is OpenAI only and uses `OPENAI_API_KEY`. Built on the AI SDK's `generateSpeech` with `openai.speech(...)`, `outputFormat: "mp3"`.

### `GET /api/health`

`{ok, version, vercel_env, openai_key_present, gemini_key_present, app_token_set, scripted, scripted_refused_in_production, models:{watch,ask,stt,speak}, problems}`. No secrets, ever.

## Missing key and scripted mode

If the chosen provider's key is absent, watch and ask answer `503 {error:"missing_key", reason:"OPENAI_API_KEY is not set"}` (Gemini: `GEMINI_API_KEY is not set`; `GOOGLE_GENERATIVE_AI_API_KEY` is also accepted). Auth is checked first, then the key, then the body, so an empty smoke call sees the 503.

`TUTOR_SCRIPTED=1` (tests only) answers from a fixed script with no key and no network. It still validates the request. It refuses to turn on when `VERCEL_ENV` is `production`: the flag is ignored, an error line is logged, and `/api/health` reports `scripted_refused_in_production: true`.

The script, for the iPad UI test:

- `/api/watch`, `problem_id` `u3-04` (the planted-mistake problem): interrupts on line 2 when `lines` contains index 2 and `history` has no earlier interrupt on line 2. `hint_written` is "Check the signs here". Every other look waits.
- `/api/watch`, any other problem: always `wait` (the clean problem).
- `/api/ask`: `transcript: "scripted question"`, a fixed `answer_text`.

## Models and where the defaults come from

Provider and model are environment variables, set per role. Checked against the vendors' own pages on 2026-11-13.

| variable | default (openai) | default (google) |
|---|---|---|
| `WATCH_PROVIDER` / `WATCH_MODEL` | `openai` / `gpt-6.1-sol` | `gemini-4-argon` |
| `ASK_PROVIDER` / `ASK_MODEL` | `openai` / `gpt-6.1-terra` | `gemini-3.8-flash` |
| `STT_MODEL` | `gpt-transcribe` | `gemini-3.5-transcribe` |

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

Also checked: `gpt-6-luna` takes text and image (cheaper, an option for ask). `gpt-6-astra` is listed at $10/$50 per million tokens, not used by default. `gpt-realtime-2.1` was not verified and is not used (this path is request and response, not a live session).

Latency is unmeasured. GPT-6.1 Sol reasons at "medium" by default; if watch is too slow, set `WATCH_MODEL=gpt-6.1-terra` or `gpt-6-luna`.

## Watch policy

`lib/policy.ts` (`WATCH_POLICY`), adapted from `tutor-timing-test/tt.py`: waiting is the default; interrupt only for a clear, consequential wrong step on a finished line; an unfinished line or a pause is not a reason; crossed-out work is a self-correction; hint, never the answer; compare with the reference worked solution but accept any valid method; name the line by its margin number. Output is a Zod schema through `generateText` + `Output.object`, then re-validated in `lib/decision.ts`.

## Logging

One JSON line per request on stdout (Vercel runtime logs): `request_id, endpoint, method, provider, model, latency_ms, image_bytes, line_count, drawing_revision, history_in, history_used, action, line, status, outcome, reason` (a label such as `model_wait`, `malformed_output`, `line_not_in_page`, `hint_reveals_answer`, `unauthorized:bad_token`, `missing_key`). Successes are logged too. Never logged: images, audio, transcripts, hints, spoken text, reasons, tokens, keys (only sizes and counts). `/api/speak` logs `text_chars, audio_bytes, purpose, voice, model, latency_ms`.

## Files

- `api/*.ts` thin Vercel entry points. `lib/` the logic: `gate.ts` (auth, key, scripted), `watch.ts`, `ask.ts`, `models.ts` (AI SDK calls), `policy.ts`, `decision.ts`, `image.ts`, `config.ts`, `log.ts`, `http.ts`, `health.ts`.
- `data/problems.json` is a copy of `../shared/problems.json` because `vercel deploy` uploads only `server/`. A test fails if they differ. Refresh with `npm run sync-problems`.
- `test/` Node's test runner via `tsx`: `npm test`. Typecheck: `npm run typecheck` (CI runs both, `.github/workflows/server.yml`).

## Deploy

Vercel project `pencil-tutor`, scope `edwards-projects-7fd27381`. From `server/`: `vercel deploy --prod --scope edwards-projects-7fd27381`. Set these in the Vercel dashboard or with `vercel env add` (never committed): `APP_ACCESS_TOKEN`, `OPENAI_API_KEY` and/or `GEMINI_API_KEY`, optionally `WATCH_PROVIDER`, `WATCH_MODEL`, `ASK_PROVIDER`, `ASK_MODEL`, `STT_MODEL`, `SPEAK_MODEL`, `SPEAK_VOICE`, `SPEAK_INSTRUCTIONS`. Do not set `TUTOR_SCRIPTED` on the production environment.

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
