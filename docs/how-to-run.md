# Pencil Tutor: how to run it

State as of 2026-11-13 morning. The plan is in `docs/plan.md`, its review in
`docs/plan.review.md`. Build details are in the root `README.md`.

## What exists

- **Server:** https://pencil-tutor.vercel.app (Vercel project `pencil-tutor`,
  team "edward's projects"). `/api/health` reports keys, models and problem
  count. The OpenAI key, Gemini key and app access token are set in Vercel
  production settings. The app token also lives in the login Keychain
  (service `pencil-tutor-app-token`).
- **iPad app:** `ios/`, built and tested on GitHub Actions
  (https://github.com/giaphutran12/pencil-tutor, private). CI draws on a
  simulated iPad and saves screenshots of a mistake being circled and of a
  clean problem being left alone (artifact `ios-screenshots`).
- **Content:** 12 algebra problems from BC Math 9 unit 3, with worked
  solutions held on the server only (`shared/problems.json`).
- **Voice:** OpenAI `gpt-live-1` (see Voice below). Server endpoints: watch, ask, speak, consult, live-session, health.
- **Watcher model:** OpenAI `gpt-6.1-sol`. To try Gemini, set `WATCH_PROVIDER`
  to `google` and `WATCH_MODEL` to `gemini-4-argon` in Vercel, then redeploy.

## Voice

**Live voice (GPT-Live-1).** While a problem is open the student talks to the tutor naturally: OpenAI's `gpt-live-1`
over WebRTC, $0.05 per minute of open session. The OpenAI key never reaches the iPad: the app sends its connection offer to
our server (`POST /api/live-session`), which relays it to OpenAI. Change the voice or model in Vercel, then redeploy:
`LIVE_VOICE` (default `gleam`; English options: quartz, ripple, vesper, willow, stone, gleam, meridian, beacon, delta,
cinder, plus marin and the older named voices) and `LIVE_MODEL` (default `gpt-live-1`). The voice was picked from the
documented voice table, **not by ear**: if it does not sound like a warm, patient tutor, try `willow`, `meridian` or
`marin` and say which one wins. The tutor's personality is `LIVE_TUTOR_INSTRUCTIONS` in `server/lib/policy.ts`.

On screen: the mic button toggles mute (green "Mic on", grey "Muted"). "Check my work", watch hints and the "looks good"
line are spoken by the same live voice. When the student asks the tutor to look at the page, GPT-Live cannot see, so it
delegates: the app captures the page and `POST /api/consult` reads it; the report comes back and the tutor says it in its own
words. After 5 minutes with no ink and no speech the session closes itself to stop the meter; hints then speak through the
old path and the mic button ("Tap to talk") reopens Live. Sessions also end after about 2 hours (OpenAI's limit) and when
the app goes to the background.

**Fallback (the earlier voice).** If Live cannot connect or drops, the screen shows hold-to-ask plus "Reconnect voice", and
everything works as before: `POST /api/ask`, then `POST /api/speak` (`gpt-4o-mini-tts`, voice `coral`; `SPEAK_MODEL`,
`SPEAK_VOICE`, `SPEAK_INSTRUCTIONS`), then the best installed device voice. **`gpt-4o-mini-tts` shuts down on 2027-01-06**
(https://developers.openai.com/api/docs/deprecations); after that `/api/speak` fails and the app uses the device voice
(for a nicer one, download an Enhanced or Premium English voice: Settings, Accessibility, Spoken Content, Voices). There is
no replacement `audio/speech` model, so there is nothing to migrate that path to.

**Session log events** (export from the share button; Debug builds also log the words as `student_said`, `tutor_said`,
`live_commentary_sent` text and `page_report`; Release builds log ids, sizes, counts and reason labels only):
`live_starting`, `live_connect`, `live_offer_ready`, `live_answer_received` (server latency), `live_connected` (total
latency), `live_connect_failed` / `live_fallback` (the reason), `live_commentary_sent`, `live_context_pushed`,
`live_context_acknowledged` (ack time), `live_delegation_requested`, `live_consult_started`, `live_consult_answered`
(latency), `live_delegation_answered` (latency), `live_hint_held` / `live_hint_released`, `live_mic`, `live_usage`
(seconds), `live_idle_close`, `live_paused`, `live_disconnected` (reason, final usage seconds), `speech_route` (live or the
old path). Speech via the old path still logs `speech_started` and `speech_fallback`.

**Not verified by any machine:** how the voice sounds, interruption feel, echo of the tutor's voice into the iPad
microphone, and whether a paraphrased hint ever changes a sign or number in real use (a headless sample of six wordings kept
every sign, number and line reference).

## Install on the iPad (morning, one time)

Edward does steps 1 to 3; the agent does the rest.

1. In a terminal: `sudo xcodebuild -runFirstLaunch` (finishes Xcode's setup;
   local builds fail without it).
2. Open Xcode, then Settings, then Accounts, and sign in with your Apple ID.
   A free Apple ID works; the app then expires after 7 days and is reinstalled
   the same way.
3. Plug the iPad in by cable, tap Trust, then on the iPad: Settings, Privacy &
   Security, Developer Mode, on, restart.
4. Agent: read the team id
   (`defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier`), write
   `ios/Config/Secrets.xcconfig` (git-ignored; token from the Keychain), then
   `xcodegen generate`, `xcodebuild ... -allowProvisioningUpdates build`,
   `xcrun devicectl device install app ...` (exact commands in `README.md`).
5. First launch on the iPad: Settings, General, VPN & Device Management, trust
   your Apple ID.

After any `xcodegen generate`, check the signing team in `ios/PencilTutor.xcodeproj/project.pbxproj`
(`grep DEVELOPMENT_TEAM`). xcodegen leaves it out of the project file; the build still takes it from
`Secrets.xcconfig`, but the project file should carry `9AKCDYB7T4` as well. The project file is git-ignored, so
putting it back is a local `sed` (what the agent did on 2026-11-13).

**Device smoke test without tapping:** launch with `--open-problem u3-01` (for example
`xcrun devicectl device process launch --device <id> --terminate-existing com.edwardtran.penciltutor --open-problem u3-01`).
The app opens that problem at once, so the live session connects with nobody touching the iPad, and the session log
(`devicectl device copy from ... Documents/session-*.jsonl`) shows `live_connected` or the fallback reason.

## What was measured (2026-11-13, synthetic pages, not real handwriting)

Pages were rendered in handwriting-style fonts, one new line every 7 seconds.
The live run used messier rendering (jitter, slant, strike-throughs) and went
through the deployed server exactly as the app calls it. A catch counts only if
the tutor names the planted wrong line; delay includes the model's own time.

| Watcher | Caught, right line | False alarms on clean work | Delay, mistake to hint |
|---|---|---|---|
| gpt-6.1-sol, live server | 12/12 | 1/12 (see note) | 3.4 s mean, 4.0 s max |
| gemini-4-argon, live server | 12/12 | 0/12 | 8.6 s mean, 13.8 s max |
| Claude Sonnet, CLI | 10/10 | 0/5 | 9.3 s mean |
| Claude Opus, CLI | 10/10 | 0/5 | 10.5 s mean |
| Claude Haiku, CLI | 9/10 | 2 (half-written lines) | 7.1 s mean |

- Note on the one gpt-6.1-sol false alarm: the "half-written" test line read
  `−8p = 12`, which is a complete but wrong equation until `+ 20` is added.
  A human tutor would flag it too. Whether to wait longer on the line the
  student is still writing is an open setting, to be decided from real use.
- Every model interrupted every self-correction before the student crossed the
  slip out. At 7-second sampling that is unavoidable, so self-correction
  tolerance is still unmeasured.
- Gemini's hints came closer to handing over the corrected step ("Multiply the
  right side by 12 too"); gpt-6.1-sol's stayed at the "check the sign" level.
- Why gpt-6.1-sol: same catches as Gemini at less than half the delay.

Code and runs: `../tutor-timing-test` (`runs/synth-17`, `endpoint/runs/`).

## The real test

Use the app on the iPad for a few problems with real mistakes, while screen
recording. Then export the session log from the app's share button. The
recording plus the log is the first real measurement: what it caught, what it
missed, what it flagged wrongly, and how long it took.
