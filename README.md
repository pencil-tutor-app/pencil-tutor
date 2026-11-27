# Pencil Tutor

A native iPad app (SwiftUI + PencilKit). A student picks a BC Math 9 equation, works it by hand with an Apple Pencil, and an AI tutor watches the page. When a finished line holds a clear mistake, the tutor circles that line in red, writes a short hint beside it and says the hint out loud. The student can also just talk to the tutor: the voice is OpenAI GPT-Live-1 (`gpt-live-1`) over WebRTC, open while a problem is on screen, with a mic mute button. If the live voice cannot connect, hold-to-ask with `/api/ask` and `/api/speak` takes over (`docs/live-voice-plan.md`).

Plan: `docs/plan.md` (the "Amendments after plan review" section wins over the sections above it). Server: `server/README.md`.

## Layout

| path | what |
|---|---|
| `ios/` | the iPad app. `project.yml` is the XcodeGen spec; there is no hand-written `.xcodeproj` |
| `ios/PencilTutor/` | app source: `Core` (models, line grouping, look policy, log), `Net` (client behind a protocol), `Drawing` (canvas, snapshot), `Audio` (fallback speech and recorder), `Live` (the GPT-Live session: protocol, transcript, WebRTC transport, controller), `Session`, `Views` |
| `ios/PencilTutorTests/` | unit tests: line grouping (fractions, crossed-out work, side calculation), look policy, stale responses, wire format, snapshot size and 2D region, page size and re-anchor, zoom-aware scroll-to-mark, tool rail choices, finger-tap gesture rules and Pencil rules, the student's own problem and `problem_text`, "Not a mistake" (stroke identity, suppression, voice take-back, overlay hit testing) |
| `ios/PencilTutorUITests/` | simulator UI tests against the in-process scripted tutor; they attach the screenshots |
| `ios/Config/` | `Secrets.example.xcconfig` (committed), `Secrets.xcconfig` (git-ignored, yours) |
| `server/` | Vercel functions: `/api/watch`, `/api/ask`, `/api/speak`, `/api/consult`, `/api/live-session`, `/api/health` |
| `shared/problems.json` | the 12 curated problems. The build copies it into the app **without** `worked_solution` and `final_answer` (`ios/Scripts/bundle_problems.py`) |
| `.github/workflows/ios.yml` | builds, runs unit tests and UI tests on a Blacksmith macOS runner (manual trigger only), uploads screenshots |

## How the app decides when to look

- Pen idle 2.5 s and the drawing changed since the last look, and never within 45 s after an interruption. Both numbers are **starting defaults, not measured values**; they are settings (gear icon) and every look is written to the session log so real use can tune them.
- "Check my work" looks right away.
- One request in flight at a time. A response for an older drawing revision is discarded (and logged) unless the line it names is unchanged.
- Line grouping (vertical overlap, stacked fractions as one line, crossed-out strokes stay in their line, far-right side calculations on their own line) is a **hypothesis**, unit tested but not yet checked against real handwriting.

## My own problem and "Not a mistake"

The first row of every course's list is "My own problem": the student types a problem (1 to 500 characters), and the page opens with it as the problem card. Requests for it carry the typed text as `problem_text`; bank problems never do. Each hint callout has a 44 pt "Not a mistake" button. Tapping it takes the circle off, remembers that ink by its strokes (not by line number, so it holds after more looks, a line written above, or a page re-anchor), stops that hint being said, and the tutor does not circle the same ink again until the student really edits it. Details, the voice cases and what is not verified: `docs/ipad-own-problem-and-dispute.md`.

## Session log

Every launch writes `session-*.jsonl` in the app's Documents folder: looks, line counts, decisions, latencies, discards and errors (and, for own problems and dismissals, `own_problem_started`, `mark_disputed`, `interrupt_suppressed_disputed`, `disputes_ended`, `hint_taken_back`: ids, counts and labels only). Export it from the share button on the problem list. It never contains the access token, page images or audio.

## CI

`ios.yml` runs on Blacksmith's `blacksmith-6vcpu-macos-26` (Apple M4, same image as GitHub's `macos-26`) with Xcode 26.6 (SDK iOS 26.5) on an iPad simulator. It is manual only, to stay inside the free Mac minutes (Blacksmith gives 3,000 free minutes a month, and one Mac minute counts as 20, so about 150 Mac minutes). Run it once when a branch is ready to merge: `gh workflow run ios.yml --ref <branch>`. Merge to main only after a green run on that exact commit. While fixing a failure, run only that one test locally, never the whole suite. `server.yml` stays on GitHub's free Linux minutes. Steps: generate the project, build, unit tests, UI tests, export the UI test screenshots as PNG files. Artifacts: `ios-screenshots` (PNGs) and `ios-results-and-logs` (xcresult bundles, build logs, the app's session log). CI uses `Secrets.example.xcconfig` as it is; the UI tests launch with `--scripted-client --any-input`, which swaps in a scripted tutor that mirrors the server's scripted mode (interrupt on line 2 of `u3-04`, wait on everything else).

## Install on the iPad (free Apple ID)

Needs: this Mac, the iPad on a cable, Xcode with the licence accepted.

1. One time: `sudo xcodebuild -license accept`; open Xcode > Settings > Accounts and sign in with your Apple ID; on the iPad turn on Settings > Privacy & Security > Developer Mode (it restarts), then plug in and tap Trust.
2. Find your team id (10 characters): `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` (look for `teamID`).
3. Run, from the repo root:

```sh
brew install xcodegen
cd ios
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# edit Config/Secrets.xcconfig: set DEVELOPMENT_TEAM (your team id); students type their own code in the app, there is no shared token
xcodegen generate
xcodebuild -project PencilTutor.xcodeproj -scheme PencilTutor -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl list devices
xcrun devicectl device install app --device <device name or id from the list> \
  build/Build/Products/Debug-iphoneos/PencilTutor.app
xcrun devicectl device process launch --device <same device> com.edwardtran.penciltutor
```

4. First launch only: on the iPad, Settings > General > VPN & Device Management > your Apple ID > Trust.

A free Apple ID signature lasts 7 days; rerun step 3 to renew it.
