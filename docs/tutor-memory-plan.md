# Tutor memory, phase 1, behind opt-in consent: implementation plan

Written 2026-11-14. Branch `tutor-memory`. Implements phase 1 of `docs/tutor-memory-design.md`, with one change of premise from Edward (2026-11-14): **memory is opt-in only.** Nothing is remembered about a student unless a parent or guardian (or an adult student, for example in college) has explicitly agreed. Without consent the tutor behaves exactly as it does today, byte for byte in the prompt.

Not legal advice. The consent text and `docs/privacy-policy.md` are drafts to review with a BC privacy lawyer before any family is asked.

## 1. What this slice is, and is not

In:

1. A consent record on the server (who agreed, which text version, when, how it was recorded) and a gate every memory feature passes through.
2. Edward's session notes per student, injected into the watch prompt when (and only when) consent is on.
3. Silent recording of attempts and hint events (counts, ids, line numbers; no pictures, no audio, no words), consent-gated.
4. `scripts/codes` commands: `consent`, `note add|list|delete`, `export`, `forget`, `forget-inactive`.
5. The rule "the tutor may only refer to dated history that is on record", made mechanical (section 5).
6. The eval gate from the design (section 9).
7. iPad: a plain-language consent screen (offered once, skippable, reachable from Settings), a "What the tutor remembers" screen (view, turn off, erase), memory status in Settings.
8. `docs/privacy-policy.md` (draft) and a public page that serves it.

Out, on purpose (each is a cut I would defend):

- **Per-skill record (the design's `skill_state`): deferred to phase 2.** Reasons: problems on `main` carry no skill key (`shared/courses/*/problems.json` fields are `id, level, prompt_*, worked_solution, final_answer, source`; the `skills.json` contract of design section 6.1 was never agreed), and there is no "solved" signal to count (design section 2: the server cannot tell finished-and-right from nothing-wrong-yet; the signal needs a new model field, `work_state`, in the highest-stakes call). A per-skill table filled with attempt counts only would look like mastery data and not be. The attempts recorded now (per problem id) are the raw material for it.
- No `student_profile`, `skill_state`, `problem_stats`, `student_misconception`, `hint_stats`, `session_summary`, `review_flag`. No new model fields, no hint rungs, no shadow mode (opt-in per student replaces it: Edward's own test code is the shadow).
- Memory is injected into `/api/watch` only. `/api/ask`, `/api/consult` and the live voice get no brief in this slice (they only record a question count).
- The one phrase of the design not built as written: a `cite` field in the watch decision. It changes the schema of the highest-stakes call and is phase 2's job. In its place the phase 1 rule is stricter: **a hint may not refer to the past at all**; notes only shape wording.

## 2. Consent: what the law asks, and what the screen does

Sources read 2026-11-14 (not legal advice):

- OPC, OIPC Alberta and OIPC BC jointly, *Guidelines for obtaining meaningful consent* (priv.gc.ca/en/privacy-topics/privacy-for-businesses/appropriate-handling-of-personal-information/collecting-personal-information-and-consent/consent/gl_omc_201805/). It says outright that "lengthy, legalistic privacy policies" make consent "illusory". Seven principles: emphasise key elements, let people control the level of detail, clear yes or no options, be innovative (just-in-time, interactive), consider the person's perspective, make consent dynamic and ongoing, be accountable. The key elements to put up front: what is collected, with whom it is shared, for what purposes, risk of harm. Complete information must still be "readily available". Children: consent from a parent or guardian for anyone unable to consent themselves, which the OPC takes to mean under 13 in all but exceptional circumstances; OIPC BC sets no age line and asks whether the person understands; for youth who can consent, the process must reasonably consider their maturity.
- BC PIPA ss. 6 to 8 (consent and notice), s. 9 (withdrawal: on notice the organisation "must inform the individual of the likely consequences", and must stop collecting, using or disclosing, "subject to section 35"), s. 23 (access), s. 35 (retention). Text read at bclaws.gov.bc.ca/civix/document/id/complete/statreg/03063_01.
- The design's section 8 (Children's Privacy Code draft, still non-binding).

So the consent surface is **layered**: a short screen with the four key elements and the controls, and the full policy one tap away (`docs/privacy-policy.md`, served at `/api/privacy`). What the screen does:

- Plain headings, each a short paragraph: **What is remembered. Why. Who sees it. How long. How to see, take, or erase it. The voice is an AI.** Written to be read in about a minute.
- Two equal buttons, "Turn on memory" and "Not now". "Turn on" is disabled until the person chooses who they are: "I am the parent or legal guardian of the student who uses this iPad" or "I am the adult student, and this is my own learning" (adult means 19 or over in BC; stricter than the OPC's 13 line, on Edward's instruction). No names are collected.
- Offered once after the code is accepted, then only from Settings. Declining changes nothing about the service.
- The record: `consent_events` row with `given_by` (`parent_guardian` | `adult_student`), `recorded_via` (`app` | `admin`), `notice_version`, timestamp. The app path is an attestation on a device a child may be holding; it cannot prove who tapped. The stronger path is Edward recording a signed paper form from `scripts/codes consent` (stores the form's date only). That limit is stated in the policy and listed as an open legal question.
- Withdrawal: one tap in the app. It states the consequence (the tutor works as before; what is stored stays unless erased) and offers "Turn off and erase everything" beside "Turn off, keep what is stored" (PIPA s. 9(2)). Memory stops at once: the next request sees the withdrawal row.
- **A new notice version means asking again.** Memory runs only while the latest consent row is a grant and its `notice_version` equals the server's current one.

The consent text is owned by the server (`lib/record/notice.ts`, versioned) and returned by `GET /api/memory`; the app renders what the server says, and the server refuses a grant that names an older version (409). One source of truth, and the stored version always names the exact words shown.

## 3. Data model: migration `004_student_memory.sql` (additive only)

Numbering: `003` is taken by the `iap-subscription` branch (`003_app_store_subscriptions.sql`); the migration runner applies any file not yet recorded, so order does not matter. Every statement is `create ... if not exists`. Student rows cascade (`on delete cascade`) so deleting a code deletes its record.

```sql
create table if not exists consent_events (          -- append-only; the latest row per student is the state
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  granted boolean not null,
  given_by text check (given_by in ('parent_guardian', 'adult_student')),   -- null on a withdrawal
  recorded_via text not null check (recorded_via in ('app', 'admin')),
  notice_version text not null,
  evidence_on date,                                   -- admin path: the date on the signed form
  at timestamptz not null default now()
);
create index if not exists consent_events_latest on consent_events (student_id, id desc);

create table if not exists human_note (               -- Edward only, never written by an app endpoint
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  session_on date not null,
  body text not null check (char_length(body) between 1 and 500),
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists human_note_pick on human_note (student_id, pinned desc, session_on desc, id desc);

create table if not exists attempt (                  -- one row per (student, app session, problem)
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  session_id text not null,
  problem_id text not null,
  looks integer not null default 0,
  interrupts integer not null default 0,
  asks integer not null default 0,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  unique (student_id, session_id, problem_id)
);
create index if not exists attempt_recent on attempt (student_id, last_at desc);

create table if not exists hint_event (               -- one per interrupt; no hint text
  id bigint generated always as identity primary key,
  student_id bigint not null references students (id) on delete cascade,
  attempt_id bigint not null references attempt (id) on delete cascade,
  line integer not null,
  drawing_revision integer not null,
  at timestamptz not null default now(),
  unique (attempt_id, drawing_revision, line)         -- a retried request is a no-op
);
create index if not exists hint_event_student on hint_event (student_id, at desc);
```

Names follow the design where it named a table (`consent_events`, `human_note`, `attempt`, `hint_event`); columns are the subset phase 1 can fill honestly. Stored: ids, counts, dates, line numbers, Edward's notes. Not stored: names, pictures, audio, transcripts, hint text, anything the student wrote or said. The session id is the app's random per-launch UUID.

Hot queries, all index-backed, no `OFFSET`:

| query | when | shape |
|---|---|---|
| brief read | each `/api/watch` when the flag is on | one statement: latest `consent_events` row for the student (`consent_events_latest`), and only if it is a current grant, the top 3 notes by `human_note_pick` (`limit 3`) |
| look write | each consenting `/api/watch` | one statement: consent check in a CTE, `insert into attempt ... on conflict (student_id, session_id, problem_id) do update` returning id, then `insert into hint_event ... on conflict do nothing` when the look interrupted |
| question write | each `/api/ask`, `/api/consult` when the flag is on | same attempt upsert, `asks + 1`, consent-checked in SQL |
| status | `GET /api/memory` | latest consent row, three counts (`count(*)` over one student's rows, tens to hundreds of rows), the 50 most recent attempts (`attempt_recent`) |
| erase | on request | one statement, data-modifying CTEs, returns the counts it deleted |

Target under 50 ms warm (design aim; Neon measured 5 to 23 ms warm for a lookup). Measured in the logs (`memory_read_ms`, `memory_write_ms`) once running; not measured before deploy and not claimed.

## 4. Server

New code lives in `server/lib/record/` (the design's chosen home, so nothing is confused with the usage meter that `students-memory.ts` implements):

| file | what |
|---|---|
| `notice.ts` | `NOTICE_VERSION`, the consent text (sections), the policy path |
| `store.ts` | `RecordStore` interface; `PgRecordStore` (all SQL, through `Db.query` only); the 150 ms read limit |
| `store-memory.ts` | `MemoryRecordStore`, a small in-memory twin for tests and the eval |
| `brief.ts` | builds the brief block (`briefFromNotes`), the prompt wrapper `withMemoryBrief` (the one named function the watch prompt change goes through), the recall-phrase guard `guardHistory` |
| `admin.ts` | `RecordAdmin`: the SQL behind `scripts/codes consent/note/export/forget/forget-inactive` |
| `endpoint.ts` | `handleMemoryStatus` (GET), `handleMemoryAction` (POST), `handlePrivacy` |

Touched existing files, each by a few lines so merges stay mechanical (other branches edit `gate.ts`, `students*.ts`, `watch.ts`, `policy.ts`, `problems.ts`, `package.json`): `gate.ts` (one optional `record?: RecordStore` in `Deps`), `http.ts` (two names in the endpoint union), `watch.ts` (read the brief beside `meterActivity`, wrap the prompt, guard the result, write the look), `ask.ts` and `consult.ts` (one `recordQuestion` call each), `db.ts` (an optional `{ timeoutMs }` third argument to `query`, default unchanged), `api/memory.ts` and `api/privacy.ts` (new Vercel entries), `package.json` (`@electric-sql/pglite` dev dependency, same version as `iap-subscription`; a `sync-policy` script). **`policy.ts` is not touched**: the brief is appended to the already-built prompt text by `withMemoryBrief`.

Feature flag: `STUDENT_RECORD=on` in the server environment. Anything else (including unset) means **no record queries at all** and `GET /api/memory` answers `{feature:"off"}`; the app then hides every memory control. So the deploy order cannot hurt: old app plus new server, new app plus old server (404 is read as "off"), flag off.

Watch path with the flag on:

1. After the problem is found, start `readBrief` (150 ms limit) concurrently with `meterActivity`; await both before the model call. Skip reasons are logged as `memory=skipped:disabled | no_notes | timeout | db_<code> | notice_outdated`, success as `memory=used`.
2. Only if consent is current **and** notes exist is the brief appended: `withMemoryBrief(buildWatchPrompt(...), brief)`. Consent without notes changes nothing in the prompt (design: "absence is a state"). No consent: the prompt string is identical to today's (test below compares them).
3. `finalizeDecision` runs as today. When a brief was injected, `guardHistory` then checks the hint text (section 5).
4. The look is recorded (consent re-checked inside the SQL, so a withdrawal between read and write wins). A failed write logs `memory_write=failed:<code>` and never fails the request.

Logging (counts, ids and labels only; the student appears as the existing 8-character hash): `memory`, `memory_notes`, `memory_brief_chars`, `memory_read_ms`, `memory_write` (`ok | skipped:no_consent | failed:<code>`), `unsupported_history` (`blocked`). Lifecycle lines: `memory_consent_granted` (given_by, via, notice version), `memory_withdrawn`, `memory_erased` (counts per table). Never logged: note text, the brief, hint text, codes.

Endpoints (`/api/memory`, code-authenticated, allowed when the month's hours are used up, never counted as activity, no model key needed):

- `GET`: `{feature, notice:{version, title, sections[], policy_url}, consent:{granted, current, given_by, recorded_via, at}, record:{attempts, looks, interrupts, notes, first_at, last_at, recent:[{problem_id, looks, interrupts, asks, last_at}]}}`. Edward's notes are not shown in the app (design section 8: they are released on request, and a child should not read a tutor's private observation unprompted); the count is.
- `POST {action:"consent", given_by, notice_version, attested:true}`: 422 without `attested: true`, 409 `notice_outdated` on a stale version.
- `POST {action:"withdraw", erase:boolean}` and `POST {action:"erase"}`: both return what was deleted.
- `GET /api/privacy`: unauthenticated, no database, serves the policy as HTML from `server/data/privacy-policy.md` (copied from `docs/privacy-policy.md`; a test fails if they differ).

## 5. The "only cite dated history on record" rule

Three layers, in order of strength:

1. **Eligibility.** The brief is built only from rows that exist: each note carries a tag and Edward's session date (`[n1] Edward, 2026-11-09: ...`). Nothing else about the past is in the prompt. Course or grade never becomes a claim of what was covered (design 6.3 rule 4).
2. **Prompt rule** (in the brief block): the record may change how a hint is worded, never whether the tutor interrupts; the page is the evidence; do not refer to earlier sessions or to what the student usually does.
3. **Code guard** (`guardHistory`, beside `finalizeDecision`'s pattern): when a brief was injected, a hint containing cross-session recall phrasing ("last time", "last session", "last week", "yesterday", "we did", "we talked", "remember when", "you always", "you usually", "you often", "you keep", "as before", "like before", "previously", "every time") is replaced by a neutral hint on the same line ("Take another look at this line.", written "Check this line"). The catch itself is kept (its detection is not in doubt, only the wording); the log says `unsupported_history_claim`. Deviation from the design, which said `wait`: dropping a correct catch to protect wording costs the student a hint they needed. This is a heuristic with false negatives; the eval reports how often it fires and does not claim zero misses. No guard runs for a student without consent (their behaviour is unchanged by definition).

The `ask` answer and the live voice are free text and get no brief in this slice, so there is nothing to guard there yet.

## 6. Admin commands (`scripts/codes`)

```
consent CODE                       show consent state and counts
consent --list                     every code: memory on/off, version, counts
consent CODE --by parent|adult [--form-date YYYY-MM-DD]     record a grant from a signed form (recorded_via admin)
consent CODE --withdraw
note add CODE "text" [--on YYYY-MM-DD] [--pin]     refused when the code has no current consent
note list CODE        note delete CODE ID
export CODE           the student's whole record as JSON on stdout (PIPA s. 23); keyed by log id, never the code
forget CODE --yes [--including-consent-log]     deletes attempts, hints, notes (and the consent log if asked); prints the counts
forget-inactive [--months 12] [--yes]           dry run by default; lists or deletes record data for codes unused for N months
```

Each prints counts and ids only. `forget-inactive` exists because the consent text promises that unused records are deleted after 12 months; a promise with no code behind it would not be meaningful consent. Whether 12 months is right, and the interaction of deletion with PIPA s. 35(1) (keep decision data one year), is an open legal question (design 8.3). The consent log is kept by default after an erase as a minimal audit trail (granted or withdrawn, when, which version, no content); the policy says so, and `--including-consent-log` removes it for anyone who objects.

## 7. iPad

New files under `ios/PencilTutor/Memory/` (`MemoryStore`, `MemoryConsentView`, `MemoryRecordView`, `MemoryStrings` for fixed UI text), a `memory...` set of methods on `TutorClient` with protocol-extension defaults (so a branch that adds another `TutorClient` conformer still compiles), implementations in `HTTPTutorClient` and `ScriptedTutorClient`.

- Settings gets a **Memory** section: "Tutor memory: On since <date> / Off / Not available". Rows: "Turn on memory" (opens consent) or "What the tutor remembers" (opens the record). Hidden entirely when the server says `feature: off`.
- `RootView` presents the consent sheet once when the account is ready, the feature is on, no decision is on record, and this code has not been offered before (UserDefaults key by code hash). `ProblemListView` is not edited (the course picker branch rewrites it).
- Consent screen: scrollable, headings and short paragraphs from the server's notice, the two-choice attestation, two equal buttons, "Read the full policy" link. Record screen: status, counts, recent problems (prompt text from the bundled bank, id otherwise), "Turn off memory" and "Erase what the tutor remembers" with confirmation dialogs.
- Calm UI: system type scaling, nothing in `lineLimit(1)`, every control at least 44 pt, text wraps rather than truncates, usable portrait and landscape. No streaks, points, or nudges to opt in.
- Scripted launch: `--scripted-client` keeps today's behaviour (feature off, no offer) unless `--memory-on` is added; `--offer-memory` also allows the once-only sheet. Existing UI tests are unaffected.
- No change to StoreKit or code-entry files.

## 8. Tests

Server (Node test runner; the Postgres tests run on GitHub CI and are skipped on the laptop unless `PT_PGLITE=1`, the convention `iap-subscription` already uses):

- **Prompt identity**: with no consent, and with the flag off, the prompt sent to the (mock) model equals today's `buildWatchPrompt` output exactly, and `store` is never called with the flag off.
- Brief: tags and dates, no notes means no block, budget (at most 300 estimated tokens, 4 characters per token, worst realistic record), pinned first, truncation logs a count.
- Guard: a table of phrases that must trigger and phrases that must not ("check the sign again" passes), neutral replacement keeps the line, label logged.
- Watch with a record store: consent on records an attempt and a hint; withdrawal between read and write records nothing; store timeout or error degrades to today's behaviour with the right skip label and a 200; question recording on ask and consult.
- Endpoints: status shape, feature off, attestation required, stale notice version 409, consent then withdraw then erase, unauthenticated privacy page, policy copy equals `docs/`.
- Notice: a test asserts the required elements exist in the text (what, why, who sees, how long, see/export/erase, AI voice, policy link) so an edit cannot silently drop one.
- No-content logging: across all of the above, no log line contains note text, a code, or hint text.
- **Real SQL on PGlite (Postgres compiled to WebAssembly, in-process, CI only)**: migration 004 applies twice, latest-consent-wins, brief read returns at most 3 notes pinned first, upserts are idempotent, look write refused without consent, erase counts, `forget-inactive`, and the same scenario table run against `MemoryRecordStore` so the twin cannot drift.

iOS: unit tests for the store's state machine (feature off hides everything, attestation required, version mismatch re-fetches, withdraw with erase, offer-once policy) with a fake client; UI test `MemoryScreensUITests` driving the scripted client through Settings, consent, record and withdrawal, with `XCUIScreen.main.screenshot()` attachments in both orientations, run on the iPad.

## 9. Eval gate (design section 7)

`server/eval/run-eval.ts` gets `--memory notes,priming`, which runs each model spec again with a synthetic consenting record injected through the same `Deps.record` seam: `notes` (two realistic tone notes) and `priming` (notes that claim a habit, "drops the minus sign when it multiplies a bracket", on pages that are correct). Paired with the no-brief run in the same invocation. Pass rule, printed as `MEMORY GATE: PASS|FAIL`: first-wrong-line hits not below the no-brief run, false alarms not above it, schema failures not above it, zero answer leaks; plus the count of `unsupported_history_claim` and the coverage ("of N looks"). One regression blocks. Model `gpt-6-luna`, 2 repetitions, about 180 calls at roughly US$0.00016 each (about US$0.03). Keys load exec-only through the Vercel CLI; they are never read by me or printed. Same caveats as the existing eval: synthetic fonts, not real handwriting; with this few students there is no power to show a learning effect, and none is claimed.

## 10. Rollout order (for Edward or the coordinator)

1. Merge `tutor-memory`. Do not deploy yet.
2. `server/scripts/codes migrate` (applies `004`, additive; also `003` if that branch merged first).
3. Deploy the server. `STUDENT_RECORD` unset: nothing changes for anyone.
4. Ship the app build. It shows no memory controls while the server says off.
5. Before any family is asked: lawyer hour on the consent text and `docs/privacy-policy.md`; fill the contact line in the policy.
6. Set `STUDENT_RECORD=on` in Vercel production and redeploy. Still nobody is remembered until a parent agrees.
7. Per family: in-app consent, or `scripts/codes consent CODE --by parent --form-date ...` after a signed form.

## 11. Verification I can and cannot do

Can: unit and SQL tests on CI, the prompt-identity test, the eval, on-device screenshots. Cannot: the lawfulness of the text, whether a child can tell what they are agreeing to (the OPC suggests testing comprehension with real users; not done), real-handwriting behaviour with a brief, anything on the production database (migration deliberately not run), processors' retention terms beyond what is written in the policy's open items.

## 12. Questions for the reviewer

1. Is deferring the per-skill table right, or is a per-problem rollup worth adding now?
2. Is PGlite as a dev-only dependency acceptable here (same one `iap-subscription` already added), or should the SQL be tested some other way?
3. Is the neutral-hint replacement a sound deviation from "wait"?
4. Anything above that should be cut from this slice?
