# Plan: move the tutor's voice to GPT-Live-1

Written 2026-11-13, revised the same day after plan review (verdict CUT, `docs/live-voice-plan.review.md`). Owner: Edward.
Supersedes the voice parts of plan amendment 11.

## Why

The voice is `gpt-4o-mini-tts`, an old model. OpenAI's deprecations page lists it (and `tts-1`, `tts-1-hd`) as
**Deprecated, shutdown Jan 6, 2027, notice Oct 1, 2026**, replacement `gpt-realtime-2.1-mini`
(https://developers.openai.com/api/docs/deprecations). The current voice model is GPT-Live-1 (`gpt-live-1`): audio and
text in and out, no image input, $0.05 per minute of session (billed per second), endpoint `v1/live/sessions`
(https://developers.openai.com/api/docs/models/gpt-live-1).

## What the docs say (read 2026-11-13, via TinyFish)

- **Connection.** WebRTC is the recommended transport for mobile. The client makes an SDP offer, our server posts
  `{session, transport:{type:"webrtc", sdp}}` to `POST /v1/live/sessions` with the project key and returns the SDP answer
  and `session.id`. Audio rides media tracks; JSON events ride a data channel labelled `oai-events`. Do not send
  `session.start` on it. Creating the session bills 15 s of voice up front, credited against the running duration.
  (guides/voice-webrtc?api=live)
- **Keys.** The Live docs describe no ephemeral client secret (the `realtime/client_secrets` flow on the same page is
  Realtime only). A WebSocket would also work from iOS, but it authenticates with the project key in a header, and the
  key must stay off the iPad. So the mechanism is the server relaying the SDP offer and answer.
- **Page access.** The Live model takes no images. Responses delegation can accept images, but the app already has an
  authenticated HTTPS path that sends the page to the vision model with validation and a size cap, so we use client
  delegation: `session.delegation.created` carries no task text, and the app answers with `session.commentary.append`
  carrying that `delegation_id`. The app keeps the transcript itself.
- **Context.** `session.thinking.append` = facts, not said; `session.commentary.append` = said aloud, may be paraphrased.
  500 tokens each, `delegation_id` required (`null` = session wide). Mute = `session.input_audio.mute`.
- **Prompting.** To request backend work the instructions must say `Generate <|SpawnThinking|>`, using the template
  headings Backchannel policy, Interruption policy, Delegation policy.
- **iOS.** OpenAI ships no Swift SDK. Use the maintained binary package `stasel/WebRTC` (release 157.0.0, 2026-11-05).

## Design (the smallest version)

Server (`server/`):
1. `POST /api/live-session` (bearer): `{session_id, problem_id, sdp}` -> `{session_id, sdp, model, voice, request_id,
   latency_ms}`. Session: `gpt-live-1`, voice `LIVE_VOICE` (default `gleam`), tutor instructions plus the problem
   statement (never the worked solution), `delegation: {type: "client"}`, and a client-event allow-list of exactly five
   events: `session.input_audio.mute`, `session.input_audio.unmute`, `session.thinking.append`,
   `session.commentary.append`, `session.close` (all named in the Live docs; confirmed against the deployed API in the
   verification step). Logs ids, sizes, latency and reason labels only.
2. `POST /api/consult` (bearer): the delegation target. Same image validation, same ask model and same `runAskModel` as
   `/api/ask`, but the question arrives as text (what the student said) plus the last few turns, and the page is the one
   captured when the delegation fired.
3. `/api/health` reports the live model and voice. `/api/watch`, `/api/ask`, `/api/speak` do not change (no page summary:
   the app knows line geometry, not recognised equations, so a summary would need a new model pipeline and go stale).

iPad (`ios/`):
1. Pure logic with unit tests: event parsing and building; transcript buffer (bounded) for follow-up questions and logs.
2. One Live audio owner. While a live session is up, `SpeechOutput` and `AudioRecorder` are never used; `TutorSession`
   sends all speech through one function that picks Live or the old path. Fallback and idle close tear the WebRTC peer
   down and deactivate its audio session before `SpeechOutput` or `AudioRecorder` may take the audio session.
3. The live session opens when a problem opens. A mic toggle replaces hold-to-talk while live (mute also disables the
   local track, not just the event).
4. Watch hints and the "Check my work" verdict go out as `session.commentary.append`. After each look the verdict (line
   count, flagged line or none) goes out as `session.thinking.append`. Nothing else is pushed.
5. A delegation captures the current page, calls `/api/consult`, and returns the answer as commentary. A result is dropped
   if the session closed meanwhile; if the drawing changed meanwhile the page is captured again once, and if it changed
   again the answer goes out marked as possibly out of date.
6. Fallback: a failed connect or a drop switches at once to hold-to-ask plus `/api/ask` and `/api/speak` (no automatic
   reconnect), with the reason logged. After an idle close, watch hints speak through `/api/speak` or the device voice, and
   the mic button reopens Live.
7. Idle close after 5 minutes of no ink and no speech is a chosen default, not a measured one.
8. The scripted-client UI-test path never opens a live session.

## Cost

Voice: $0.05 per minute of open session ($3.00 per hour). Delegation calls and watch looks bill at the existing ask and
watch model rates. No claim is made that Live is cheaper, faster or better sounding than the old path; latency and
usage seconds are logged so the first real lessons can say.

## Out of scope

Responses delegation, sideband WebSocket (a Vercel function cannot hold one), custom voices, session storage and forking,
automatic reconnect, a page summary or per-ink-change description, a guarantee that a hint never lands mid-sentence
(Live has no completed-turn event, and Live handles being interrupted itself), a new TTS path (OpenAI's named replacement
`gpt-realtime-2.1-mini` is a Realtime model; whether it works on `v1/audio/speech` was not checked on its model page; the
old `/api/speak` ages out on its shutdown date and the device voice remains its fallback).

## Verification

Server: unit tests for the files touched; typecheck and the full suite on GitHub CI. Deployed: `/api/health` shows the
model; `/api/live-session` returns 200 with a real SDP answer and no key in the body. Device: build, install and launch
on the iPad with a launch argument that opens a problem, then read the app's session log. Extra evidence, not the gate:
a scratch headless WebRTC client against the deployed server (delegation, consult, hint wording, mute events).
What no machine here can check, and is reported unverified: how the voice sounds, interruption feel, echo on the
speaker, mute with a real finger, idle close, fallback on a dropped network, and whether spoken hints keep their signs
and line numbers when the model paraphrases (the headless run checks a sample of wordings only).
