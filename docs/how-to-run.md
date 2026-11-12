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
- **Watcher model:** OpenAI `gpt-6.1-sol`. To try Gemini, set `WATCH_PROVIDER`
  to `google` and `WATCH_MODEL` to `gemini-4-argon` in Vercel, then redeploy.

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
