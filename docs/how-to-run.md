# Pencil Tutor: how to run it

State as of 2026-11-13 morning. The plan is in `docs/plan.md`, its review in
`docs/plan.review.md`. Build details are in the root `README.md`.

## What exists

- **Server:** https://pencil-tutor.vercel.app (Vercel project `pencil-tutor`,
  team "edward's projects"). `/api/health` reports keys, models, the voice
  provider and problem count. The OpenAI key and Gemini key are set in Vercel
  production settings. **Students sign in with a code, not the old shared token**
  (see Student codes and hours below); `APP_ACCESS_TOKEN` is no longer read by the
  server and can be deleted from Vercel once no old build is in use.
- **Database:** Neon Postgres (Vercel Marketplace, Free plan, resource
  `pencil-tutor-db`), connected to the project as `DATABASE_URL`. Holds student
  codes and monthly usage only.
- **iPad app:** `ios/`, built and tested on GitHub Actions
  (https://github.com/giaphutran12/pencil-tutor, private). CI draws on a
  simulated iPad and saves screenshots of a mistake being circled and of a
  clean problem being left alone (artifact `ios-screenshots`).
- **Content:** the course banks under `shared/courses/` (BC Math 5 to 9, Foundations of Math and Pre-calculus 10, Pre-calculus and Foundations of Math 11 and 12,
  Calculus 12, Calculus I, Linear Algebra, Discrete Mathematics; 1,024 problems at 15 courses) plus the
  original 12 BC Math 9 unit 3 problems (`shared/problems.json`). Worked solutions are held on the server only. The iPad opens on
  a course picker (Elementary, High school, College), then the course's problem list, then the page; it remembers the last course.
- **Voice:** ElevenLabs Eleven v4 Turbo, tap-to-talk (see Voice below). GPT-Live is a premium option, off unless a
  code's plan has it. Server endpoints: watch, ask, speak, consult, live-session, me, heartbeat, health.
- **Models:** every course, college ones too, runs on OpenAI `gpt-6-luna` for watch and for ask/consult. A course moves to
  `gpt-6.1-sol` only with `"tier": "advanced"` in its `course.json`, and only after handwriting results are measured (plan amendment
  18; amendment 14 measured high school only). To try
  another model, set `WATCH_MODEL` / `ASK_MODEL` (high school) or `WATCH_MODEL_ADVANCED` / `ASK_MODEL_ADVANCED` in Vercel
  and redeploy; for Gemini also set the matching `_PROVIDER` to `google`. Reasoning effort: `WATCH_EFFORT`, `ASK_EFFORT`
  (`none`, `low`, `medium`, `high`; unset means the provider default).

## Adding a course (2026-11-14, amendment 18)

1. Put `problems.json` (and a README) in `shared/courses/<slug>/`. Optionally add `course.json` with `title`, `group`
   (`elementary`, `high_school`, `college`) and `grade` (`null` for college); without it the title and group come from the folder
   name and the problems' level, and the build prints a note.
2. `npm --prefix server run build-courses`. It validates every problem in every course, fails on a duplicate id anywhere, and
   rewrites `shared/courses/index.json` (the manifest the iPad bundles) and `server/data/problems.json` (what the server loads).
   Commit both. CI fails (`server/test/courses.test.ts`) when either is stale or a folder is missing from the manifest.
3. Deploy the server (`vercel deploy --prod`, from `server/`) so the tutor knows the new problems, and rebuild and install the iPad
   app so the picker lists the course. Both are needed: the app bundles the prompts and the server holds the solutions. An older app
   keeps working; it just does not list the new course.

## Voice (the base plan, 2026-11-14)

**Tap-to-talk, every utterance in ElevenLabs Eleven v4 Turbo.** The mic button records a question (tap to start, tap again to
send, auto-stop at 30 seconds); `POST /api/ask` answers with the page in view; `POST /api/speak` speaks the answer, every hint
and every check verdict. The audio streams as 24 kHz 16-bit PCM and the iPad starts playing after about 150 ms of it. Settings
(Vercel env, all optional except the key): `ELEVENLABS_API_KEY` (secret), `ELEVENLABS_VOICE_ID` (now Eric, the premade American
male voice `cjVigY5qzO86Huf0OWal`; set to the clone's id later), `ELEVENLABS_MODEL` (default `eleven_v4_turbo`),
`ELEVENLABS_STABILITY` (0.5) and `ELEVENLABS_SIMILARITY` (0.75). Fallback chain: ElevenLabs, then OpenAI text-to-speech (same
text, same PCM format, `SPEAK_*` settings), then the device voice. Every fallback is logged with its reason on the server
(`voice_fallback`) and in the app's session log (`speech_fallback`); the response header `x-voice-provider` says which voice spoke.

**Setting the ElevenLabs key (one time; the only manual step).** The server's key could not be created from the command
line: the ElevenLabs CLI's sign-in lacks the `service_account_write` permission, and a restricted key can only be made through a
service account. So, in the browser:

1. elevenlabs.io, then Developers, then API Keys, then Create API Key.
2. Name it `pencil-tutor-server`. Turn on "Restrict key", set **Text to Speech: Access** and everything else **No Access**. A
   credit limit (for example 150,000) is a good extra guard.
3. Click the copy button on the new key (it is shown once).
4. In a terminal: `server/scripts/set-elevenlabs-key`. It reads the key from the clipboard, saves it to Vercel production as a
   secret, clears the clipboard and redeploys. The key is never printed or typed into a chat.
5. Check: `server/scripts/live-check` (below). `/api/health` then says `"voice_provider": "elevenlabs"`.

Until that is done the server speaks through the OpenAI fallback and says so (`x-voice-fallback: elevenlabs_key_not_set`).

**Making the voice clone (when the recording exists).** `server/scripts/clone-voice /path/to/recording.m4a` creates an Instant
Voice Clone named "Edward Tutor" and prints only the new voice id (it uses the ElevenLabs CLI's sign-in, or
`ELEVENLABS_API_KEY` if set). Then `printf '<that id>' | vercel env add ELEVENLABS_VOICE_ID production --force` and
`vercel deploy --prod` from `server/`. ElevenLabs advises a clean recording in one speaking style: Eleven v4 copies the source
faithfully, flaws included. Not done yet.

**ElevenLabs capacity.** The Creator plan gives this account 157,028 credits a month (1 character = 1 credit on v4 Turbo,
measured) and cannot be extended; when it runs out the voice falls back to OpenAI. See plan amendment 13.

## Student codes and hours

Each student has a random 8-character code (shown as `ABCD-EFGH`; no names are stored anywhere). The app asks for it once and keeps
it in the Keychain; the server checks it on every request. Edward keeps the code-to-student list offline. Run the admin tool from
`server/` in the main checkout (it is linked to the Vercel project; it loads the production database address for that one command
only and never prints it):

```
server/scripts/codes create [--count N] [--hours H | --minutes M] [--live]   # new codes (default 8 hours a month, live voice off)
server/scripts/codes list                                                    # every code, this month's use, minutes left, log id
server/scripts/codes topup CODE --hours 2                                    # add time to this month only
server/scripts/codes disable CODE      /  enable CODE                        # turn a code off or back on
server/scripts/codes live CODE on|off                                        # allow the premium live voice
server/scripts/codes delete CODE --yes                                       # remove a test code and its usage
server/scripts/codes migrate                                                 # create/update the tables (safe to repeat)
```

`list` prints the code and its **log id** (an 8-character hash): server and app logs carry only the log id, never the code.

**What counts as an hour.** Only real working time. The meter adds up the gaps between the student's activity moments (ink, a
question, the tutor looking, live voice talk); a gap longer than 60 seconds counts as zero, and nothing is charged ahead of time or
after the last moment. The app sends a heartbeat every 30 seconds only when there is student activity it has not reported yet, so an
iPad left on the table counts nothing. (This replaced the earlier "2 minutes forward" rule on 2026-11-14; see `docs/plan.md`.) After
pulling this change, run `server/scripts/codes migrate` once to add the `last_activity_at` column before deploying the server. The month is the calendar month in America/Vancouver and resets
on the 1st. At 80% the tutor says how much is left; at 100% the tutor says the hours are used up and to ask Edward, watching and
asking stop, drawing still works. The student sees "N min left" on the problem list and the problem screen.

**Live check with receipts.** `server/scripts/live-check` makes two throwaway codes (normal and a 1-minute cap), checks a valid and an
unknown code, times three spoken sentences (headers, first audio byte, total, bytes, which voice spoke), exercises the cap and the
notices, checks live voice is refused on a plan without it, and deletes both codes. Run it after any deploy.

**Operations.** Neon Free sleeps its database after 5 minutes idle; the first query after that takes about 50 to 80 ms longer (the
app wakes it with `GET /api/me`). If the database is unreachable the server answers 503 `database_unavailable` and the app keeps
the stored code. Every request logs `db_queries` and `db_ms`. Money: Neon Free is $0; if its compute hours (100 a month) ever ran
out, the plan would need a paid tier (Edward's call).

## Premium: live voice (GPT-Live-1, off by default)

Only a code whose plan has `live: true` reaches this. While a problem is open the student talks to the tutor naturally: OpenAI's `gpt-live-1`
over WebRTC, $0.05 per minute of open session. The OpenAI key never reaches the iPad: the app sends its connection offer to
our server (`POST /api/live-session`), which relays it to OpenAI. Change the voice or model in Vercel, then redeploy:
`LIVE_VOICE` (default `meridian`; English options: quartz, ripple, vesper, willow, stone, gleam, meridian, beacon, delta,
cinder, plus marin and the older named voices) and `LIVE_MODEL` (default `gpt-live-1`). The voice was picked from the
documented voice table, **not by ear**: if it does not sound like a warm, patient tutor, try `willow`, `meridian` or
`marin` and say which one wins. The tutor's personality is `LIVE_TUTOR_INSTRUCTIONS` in `server/lib/policy.ts`.

On screen: the mic button toggles mute (green "Mic on", grey "Muted"). "Check my work", watch hints and the "looks good"
line are spoken by the same live voice. When the student asks the tutor to look at the page, GPT-Live cannot see, so it
delegates: the app captures the page and `POST /api/consult` reads it; the report comes back and the tutor says it in its own
words. After 5 minutes with no ink and no speech the session closes itself to stop the meter; hints then speak through the
old path and the mic button ("Tap to talk") reopens Live. Sessions also end after about 2 hours (OpenAI's limit) and when
the app goes to the background.

**Fallback (the base-plan path).** If Live cannot connect or drops, the screen shows tap-to-talk plus "Reconnect voice", and
everything works as in the base plan: `POST /api/ask`, then `POST /api/speak` (ElevenLabs, then OpenAI `gpt-4o-mini-tts`, voice
`coral`; `SPEAK_MODEL`, `SPEAK_VOICE`, `SPEAK_INSTRUCTIONS`), then the best installed device voice. **`gpt-4o-mini-tts` shuts down on 2027-01-06**
(https://developers.openai.com/api/docs/deprecations); after that `/api/speak` fails and the app uses the device voice
(for a nicer one, download an Enhanced or Premium English voice: Settings, Accessibility, Spoken Content, Voices). There is
named replacement, `gpt-realtime-2.1-mini`, is a Realtime model (OpenAI's text-to-speech guide says to migrate to it "using the Realtime API"; a third-party article says it does not support `v1/audio/speech`; neither was checked against the model page), so `/api/speak` is not migrated.

**Session log events** (export from the share button; Debug builds also log the words as `student_said`, `tutor_said`,
`live_commentary_sent` text and `page_report`; Release builds log ids, sizes, counts and reason labels only):
`live_starting`, `live_connect`, `live_offer_ready`, `live_answer_received` (server latency), `live_connected` (total
latency), `live_connect_failed` / `live_fallback` (the reason), `live_commentary_sent`, `live_context_pushed`,
`live_context_acknowledged` (ack time), `live_delegation_requested`, `live_consult_started`, `live_consult_answered`
(latency), `live_delegation_answered` (latency), `live_hint_held` / `live_hint_released`, `live_mic`, `live_usage`
(seconds), `live_idle_close`, `live_paused`, `live_disconnected` (reason, final usage seconds), `speech_route` (live or the
base-plan path). The base-plan voice logs `speech_started`, `speech_first_audio` (milliseconds from the request to the first
audio byte), `speech_finished` (total bytes, milliseconds, which voice spoke, the server's fallback reason if any, and a running
character count for the app run; counts only, never the text) and `speech_fallback` (the specific reason the device voice took
over).

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
   `ios/Config/Secrets.xcconfig` (git-ignored; the server URL and the team id; the app no longer carries a shared token), then
   `xcodegen generate`, `xcodebuild ... -allowProvisioningUpdates build`,
   `xcrun devicectl device install app ...` (exact commands in `README.md`).
5. First launch on the iPad: Settings, General, VPN & Device Management, trust
   your Apple ID. Then type the student's code on the first screen (once; it stays in the Keychain).

After any `xcodegen generate`, check the signing team in `ios/PencilTutor.xcodeproj/project.pbxproj`
(`grep DEVELOPMENT_TEAM`). xcodegen leaves it out of the project file; the build still takes it from
`Secrets.xcconfig`, but the project file should carry `9AKCDYB7T4` as well. The project file is git-ignored, so
putting it back is a local `sed` (what the agent did on 2026-11-13).

**Device smoke test without tapping:** launch with `--student-code XXXXXXXX --open-problem u3-01` (for example
`xcrun devicectl device process launch --device <id> --terminate-existing com.edwardtran.penciltutor --student-code XXXXXXXX --open-problem u3-01`).
`--student-code` stores the code in the Keychain and works in Debug builds only (a Release build ignores it). The app opens that
problem at once, so the code is checked, the heartbeat and the allowance chip start, and the session log
(`devicectl device copy from ... Documents/session-*.jsonl`) shows the checks, `speech_*` events, and (only for a live plan) `live_connected` or the fallback reason.
The iPad must be unlocked or the launch is refused ("device was not, or could not be, unlocked").

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

## Voice latency and per-request cost (2026-11-14)

Time to first audio byte, 77-character sentence (about 4.7 s of speech), measured from Edward's Mac:

| path | first audio | whole sentence | notes |
|---|---|---|---|
| ElevenLabs v4 Turbo direct, streaming (via the ElevenLabs CLI, 4 runs) | 642, 655, 688 ms; 1,164 ms on the cold first run | 1.17 to 1.67 s | includes CLI start-up and this Mac's network; **not through our server** |
| OpenAI fallback through the deployed server (3 runs; not streamed, so first audio waits for the whole clip) | 2,189 to 2,343 ms | 2.9 to 3.5 s | server time 1.3 to 1.8 s |
| **ElevenLabs through the deployed server** | **not measured: no ElevenLabs key is in Vercel yet** | | run `server/scripts/live-check` after `set-elevenlabs-key` |

Database time per request on the deployed server (log field `db_ms`): 5 to 23 ms warm for the code lookup, 53 to 82 ms for the
first query after idle; a counted request (lookup plus counting) is 2 queries, 18 to 65 ms in total. One page look
(`/api/watch`, `gpt-6.1-sol`, 4 looks): 1,841 input tokens, about 45 output tokens, about $0.0041 estimated, 2.5 s of model time.
That was before amendment 14; `gpt-6-luna` now does the look at about $0.00016 (see the next section).

## Model eval and cost per look (2026-11-14)

Every watch, ask and consult call logs `model, level, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens,
model_ms, est_cost_usd, cost_basis` (counts only). To see real cost per session, add up `est_cost_usd` from the Vercel runtime
logs for the session's requests. The price table is `server/lib/pricing.ts` (sources and date in the file).

Re-run the model comparison (a script, not part of CI; it makes real API calls, about $0.01 to $0.03 per 30-page pass per cheap
model and about $0.25 for Sol). Keys load from an env file with Node's flag and are never printed:

```sh
python3 server/eval/make_fixtures.py        # only to regenerate the 30 pages (needs Pillow and macOS fonts); they are committed
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-eval.ts \
  --models openai:gpt-6-luna,openai:gpt-6.1-sol,google:gemini-4-argon --reps 2 --run my-run
```

Model spec is `provider:model[:effort]`. It drives the real `handleWatch` / `handleConsult`. Results append to
`server/eval/results/<run>.jsonl` (a rerun with the same `--run` resumes) and a table prints; `--budget` stops at an estimated
spend (default $4). Re-print a table with `tsx server/eval/score.ts server/eval/results/<run>.jsonl`. The committed run behind
the defaults is `server/eval/results/main2.md`.

**The 14 new courses (2026-11-15).** A second page set covers grades 5 to 12 and college: 3 problems per course, a correct page and a
one-planted-mistake page each (84 pages), plus a "messy" copy of the same pages. Build, run and report (watch role only):

```sh
python3 server/eval/make_course_fixtures.py            # clean set -> server/eval/fixtures/courses/  (needs Pillow and fonttools; downloads OFL fonts)
python3 server/eval/make_course_fixtures.py --messy    # harder copy -> server/eval/fixtures/courses-messy/
server/node_modules/.bin/tsx --env-file=/path/to/.env.local server/eval/run-eval.ts --models openai:gpt-6-luna --roles watch \
  --fixtures courses --run courses-my-run --max-calls 100 --budget 1
python3 server/eval/report_courses.py server/eval/results/courses-my-run.jsonl --fixtures courses --examples
```

`--max-calls` is a hard cap on looks (rows in the results file). The findings are in `docs/evals/2026-11-15-courses-watch-eval.md`.

**Pulling Edward's real handwriting for the next eval.** Debug builds only (same gate as `TutorSession.logsWords`; Release never
writes them) save each page picture sent to watch or consult in the app's Documents folder, next to the session log, as
`page-<time>-<session>-watch-w<N>-r<revision>.png` or `...-consult-d<id>-a<attempt>-r<revision>.png`. The session log's
`page_saved` events name the file and size. They are not uploaded and not part of the share-sheet export. Copy them off:

```sh
xcrun devicectl device copy from --device 00008030-0002101902D0202E --domain-type appDataContainer \
  --domain-identifier com.edwardtran.penciltutor --source Documents --destination ~/Desktop/pencil-pages
```

## The real test

Use the app on the iPad for a few problems with real mistakes, while screen
recording. Then export the session log from the app's share button. The
recording plus the log is the first real measurement: what it caught, what it
missed, what it flagged wrongly, and how long it took.
