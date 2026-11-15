# Tutor memory, phase 1, behind opt-in consent: implementation plan

Written 2026-11-14. Branch `tutor-memory`. Implements phase 1 of `docs/tutor-memory-design.md`, with one change of premise from Edward (2026-11-14): **memory is opt-in only.** Nothing is remembered about a student unless a parent or guardian (or an adult student, for example in college) has explicitly agreed. Without consent the tutor behaves exactly as it does today, byte for byte in the prompt.

Not legal advice. The consent text and `docs/privacy-policy.md` are drafts to review with a BC privacy lawyer before any family is asked.

**Revision 4, final scope (after plan review 3, verdict REDO again; the coordinator capped the loop at three rounds, so there is no review 4).** Review 3 kept the shape (consent controls, admin commands, four tables, one spoken rewrite after detection with the original written hint and fallback) and objected to claims and to the erase mechanism. What I do with it: **retracted claims** — "the spoken hint is never sent back to the server" is false (it goes to `/api/speak`, and with the live voice into transcripts and `/api/consult` recent turns, `TutorSession.swift:694`, `SpeechOutput.swift:199`, `LiveVoice.swift:268`, `consult.ts:72`); "detector inputs on later looks are identical" is too strong (history carries delivery timestamps and discarded interrupts never enter history, `TutorSession.swift:1031,1058`; the valid promise is **the detection call for the same incoming request is unchanged**); "one statement at a time" and "one second removes everything" are unproven (the door has no serialization, `db.ts:43`) so **the sweep is removed**: erase is withdraw then delete in one statement, and a write already in flight can leave a late row, which is **an open objection left for Edward and the coordinator**, along with the review's other open items (section 12). The "EXPLAIN must pick this index" assertion is removed. "Times the tutor stepped in" is labelled "server decisions" because the iPad discards stale ones. The rewrite is shipped behind its **own switch** (`STUDENT_RECORD_REWORD=on`, off by default, inside `STUDENT_RECORD=on`), so the part with open objections can be decided separately without a code change. Everything else is built as written.

**Revision 3 (after plan review 2, verdict REDO, 2026-11-14).** Review 2 found a hole in revision 2: the app stores the *written* hint in its history and sends it back in the next look's detection prompt (`TutorSession.swift:1051` appends `hintWritten`; `:920` sends `history`; `policy.ts:82` puts it in the prompt), so a reworded written hint would have leaked memory into later detection. I confirmed it. Revision 3: **only the spoken hint is reworded; the written hint (8 words, the one that goes into history, onto the page and to the live voice) is always the original detection output.** The spoken hint is never sent back to the server (`TutorSession.swift:1052` history takes `hintWritten` only; speech goes to `tell(...)`), so detector inputs for the next look are the same for every student. Also taken from review 2: notes are read only after detection chooses an interrupt, inside the same statement that records the look (so ordinary waits cost no extra read); written-hint rewriting deleted; the claim that a phrase filter "mechanically prevents" history dropped (it is a heuristic, reported with its misses); the unscoped exemption from regression checks dropped (replaced by a test across consecutive looks); lifetime-count displays dropped; the eval gets a reviewed pass rule; erase now withdraws first, then deletes, then sweeps, and the policy and plan say plainly what remains unverified; the privacy policy was out of step with the design and is reconciled. Not taken: nothing.

**Revision 2 (after plan review 1, verdict REDO, 2026-11-14).** The reviewer's central point, accepted: in revision 1 the notes entered the same model call that decides whether to interrupt, so "notes only shape wording" rested on a prompt sentence and a phrase filter, and keeping an interrupt while swapping its words could preserve a false accusation (`watch.ts:69`, `decision.ts:26`). Revision 2 makes the promise structural: **the detection call is untouched and never sees a note.** Notes act only in a second, text-only step that runs after detection has decided to interrupt and can only reword the hint (section 4). The reviewer offered the other branch (accept and measure prompt influence); I chose strict independence because it matches Edward's design rule ("memory never changes whether the tutor interrupts", design 5) and "a false alarm is the worst failure", and it is provable by a byte-identity test instead of a statistical eval. Cost: one extra small text call, and about one extra second, only on an interrupt, only for a consenting student. Other review points taken: the neutral-hint substitution, the in-memory database twin, the keyword test of the notice and the 50-row dashboard are cut; the notice text is now pinned by hash; management stays available when recording is switched off; the leak check for hints is made real. Points overruled with a reason are in section 12.

## 1. What this slice is, and is not

In:

1. A consent record on the server (who agreed, which text version, when, how it was recorded) and a gate every memory feature passes through.
2. Edward's session notes per student, used to **reword the spoken hint** after detection has already decided to give one, when (and only when) consent is on. Detection and the written hint are unchanged.
3. Silent recording of attempts and hint events (counts, ids, line numbers; no pictures, no audio, no words), consent-gated.
4. `scripts/codes` commands: `consent`, `note add|list|delete`, `export`, `forget`, `forget-inactive`.
5. The rule "the tutor may only refer to dated history that is on record", made mechanical (section 5).
6. The eval gate from the design (section 9).
7. iPad: a plain-language consent screen (offered once, skippable, reachable from Settings), a "What the tutor remembers" screen (view, turn off, erase), memory status in Settings.
8. `docs/privacy-policy.md` (draft) and a public page that serves it.

Out, on purpose (each is a cut I would defend):

- **Per-skill record (the design's `skill_state`): deferred to phase 2.** Reasons: problems on `main` carry no skill key (`shared/courses/*/problems.json` fields are `id, level, prompt_*, worked_solution, final_answer, source`; the `skills.json` contract of design section 6.1 was never agreed), and there is no "solved" signal to count (design section 2: the server cannot tell finished-and-right from nothing-wrong-yet; the signal needs a new model field, `work_state`, in the highest-stakes call). A per-skill table filled with attempt counts only would look like mastery data and not be. The attempts recorded now (per problem id) are the raw material for it.
- No `student_profile`, `skill_state`, `problem_stats`, `student_misconception`, `hint_stats`, `session_summary`, `review_flag`. No new model fields, no hint rungs, no shadow mode (opt-in per student replaces it: Edward's own test code is the shadow).
- Memory touches `/api/watch` hints only. `/api/ask`, `/api/consult` and the live voice get no notes (they only record a question count). The live voice speaks watch hints, so it gets reworded hints for free.
- Not built as the design wrote it: a `cite` field in the watch decision (it changes the highest-stakes call's schema; phase 2). In its place the phase 1 rule is stricter: **a hint may not refer to the past at all**; notes only shape wording.
- Not in this slice (review 1): a second grant UI path beyond what Edward asked for, a 50-row dashboard, an in-memory database twin, a keyword test of the notice, neutral-hint substitution.

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
  notice_hash text,                                   -- SHA-256 of the exact text shown (null on a withdrawal)
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

Names follow the design where it named a table (`consent_events`, `human_note`, `attempt`, `hint_event`); columns are the subset phase 1 can fill honestly. Stored: ids, counts, dates, line numbers, Edward's notes. Not stored: names, pictures, audio, transcripts, hint text, anything the student wrote or said. The session id is the app's random UUID, created per problem screen. Interrupts are counted from `hint_event` rows (idempotent under retries), not stored twice. The server tables hold no hint text; the device session log and live context do hold hints (see section 12).

Hot queries, all index-backed, no `OFFSET`:

| query | when | shape |
|---|---|---|
| look write and notes read | each `/api/watch` when the flag is on, after detection | one statement: consent check in a CTE (latest `consent_events` row, `consent_events_latest`), `insert into attempt ... on conflict (student_id, session_id, problem_id) do update`, the `hint_event` insert when the look interrupted, and, only for an interrupt by a student with current consent, the top 3 notes by `human_note_pick` (`limit 3`) |
| question write | each `/api/ask`, `/api/consult` when the flag is on | same attempt upsert, `asks + 1`, consent-checked in SQL |
| status | `GET /api/memory` | latest consent row, the notes count, the 10 most recent attempts (`attempt_recent`), each with its hint count |
| erase | on request | one statement, data-modifying CTEs, returns the counts it deleted |

Target under 50 ms warm (design aim; Neon measured 5 to 23 ms warm for a lookup). Measured in the logs (`memory_read_ms`, `memory_write_ms`) once running; not measured before deploy and not claimed.


## 4. Server

New code lives in `server/lib/record/` (the design's chosen home, so nothing is confused with the usage meter that `students-memory.ts` implements):

| file | what |
|---|---|
| `notice.ts` | `NOTICE_VERSION`, the consent text (sections), its SHA-256, the policy path |
| `store.ts` | `RecordStore` interface; `PgRecordStore` (all SQL, through `Db.query` only); the 150 ms read limit |
| `reword.ts` | the post-detection hint rewriter and the recall-phrase guard |
| `admin.ts` | `RecordAdmin`: the SQL behind `scripts/codes consent/note/export/forget/forget-inactive` |
| `endpoint.ts` | `handleMemoryStatus` (GET), `handleMemoryAction` (POST), `handlePrivacy` |

Touched existing files, each by a few lines so merges stay mechanical (other branches edit `gate.ts`, `students*.ts`, `watch.ts`, `policy.ts`, `problems.ts`, `package.json`): `gate.ts` (one optional `record?: RecordStore` in `Deps`), `http.ts` (two names in the endpoint union), `watch.ts` (after `finalizeDecision`: one record-and-read statement, then for an interrupt one call to the spoken rewriter), `ask.ts` and `consult.ts` (one `recordQuestion` call each), `db.ts` (an optional `{ timeoutMs }` third argument to `query`, default unchanged), `api/memory.ts` and `api/privacy.ts` (new Vercel entries), `package.json` (`@electric-sql/pglite` dev dependency, same version as `iap-subscription`; a `sync-policy` script). **`policy.ts` and `models.ts` are not touched**, and `buildWatchPrompt` and `WATCH_POLICY` are not changed at all: the detection prompt is the same string for every student.

**Feature flag `STUDENT_RECORD=on`** gates *new* memory activity only: reading notes, rewording, recording, and accepting a new grant. Anything else (including unset) means those make **no record queries** and `POST consent` answers 404 `memory_not_available`. Management of an existing record is never gated by the flag (review 1): `GET /api/memory`, withdraw and erase keep working after a rollback, and `GET` returns `feature:"off"` together with the consent state and counts when a record exists. The app shows the Memory section when the feature is on or a record exists. Old app plus new server, and new app plus old server (404 is read as "unavailable"), both behave.

### Watch path with the flag on

1. **Detection runs exactly as today** and first: `buildWatchPrompt`, `runWatchModel`, `finalizeDecision`, same prompt, image and schema for every student, notes absent. Nothing about memory is read before it.
2. **After detection, one statement** records the look and, when the result is an interrupt, also records the hint event and returns consent state and up to 3 notes (a `consented` flag and the notes come back from the same snapshot that authorised the insert; a student without current consent gets no insert and no notes). Ordinary waits therefore cost one write and no note read. With the flag off, no statement runs at all; with it on, a student without consent costs one statement per look that inserts nothing (the statement carries the consent check; there is no way to learn "no consent" without asking the database, so "no consent means no record query" is not claimed).
3. If the result is an interrupt and notes came back: a second, text-only call (`rewordSpoken`, the watch model, 2 s limit, no image, no reference solution, no final answer in its input). Input: the problem's plain prompt, the line number, the spoken hint just produced, and the notes with their tags and dates. Output (schema-checked): a new `hint_spoken` only. Rules in its system text: keep the same meaning and the same kind of slip; change only tone and wording to suit the notes; add no facts, values or corrected lines; do not refer to earlier sessions, to the notes, or to what the student usually does. `action`, `line` and `hint_written` are copied from the detection result untouched.
4. Checks on the reworded spoken hint; any failure keeps the **original spoken hint**: parse failure, timeout or provider error, the answer-leak test `finalizeDecision` applies (`squash` contains `final_answer`), recall phrasing (section 5), over 400 characters. Each fallback logs `reword=fallback:<reason>`; success logs `reword=used`, with tokens and cost tagged `operation: memory_reword` through `usageFields`.
5. A failed write logs `memory_write=failed:<code>` and never fails the request; a failed or empty note read means no reword.

Why only the spoken hint, and what that does and does not give. The written hint goes into the app's history and is sent back into the next look's detection prompt; the spoken hint is played (and, through `/api/speak` and the live voice's transcript, can reach `/api/speak` and `/api/consult` as text, but never the detection prompt). Rewording only the spoken one keeps the **detection call for the same incoming request** unchanged for every student. It does not mean semantic correctness: a reword could change what the explanation says. That is why the eval below has a reviewed pass rule, and why the guard is described as a heuristic. It also does not mean identical delivery: the second call adds delay, and the app discards a response if the student changed the line meanwhile (`TutorSession.swift:1027`); the 2 s limit bounds the delay, and a discard of a valid catch because of it is a possible cost that I will measure and report. The live voice is told the written hint (`pushVerdict`), so a live-plan student gets personalised wording only on the spoken path.

Logging (counts, ids and labels only; the student appears as the existing 8-character hash): `memory_notes`, `reword` (`used | fallback:<reason>`), `memory_write` (`ok | skipped:no_consent | failed:<code>`), `memory_write_ms`. Lifecycle lines: `memory_consent_granted` (given_by, via, notice version), `memory_withdrawn`, `memory_erased` (counts per table). Never logged: note text, hint text, codes.

Endpoints (`/api/memory`, code-authenticated, allowed when the month's hours are used up, never counted as activity, no model key needed):

- `GET`: `{feature, notice:{version, title, sections[], policy_url}, consent:{granted, current, given_by, recorded_via, at}, record:{notes, recent:[up to 10 of {problem_id, looks, interrupts, asks, last_at}]}}` (no lifetime totals: nothing is counted across a student's whole history; the notes count is one small indexed count). Edward's notes are not shown in the app (design section 8: released on request; a child should not read a tutor's private observation unprompted); the count is.
- `POST {action:"consent", given_by, notice_version, attested:true}`: 422 without `attested: true`, 409 `notice_outdated` on a stale version, 404 when the flag is off.
- `POST {action:"withdraw", erase:boolean}` and `POST {action:"erase"}`: both return what was deleted.
- `GET /api/privacy`: unauthenticated, no database, serves the policy as HTML from `server/data/privacy-policy.md` (copied from `docs/privacy-policy.md`; a test fails if they differ).

Races (revision 4, honest version). Withdrawal and erase are one statement: insert the withdrawal row and delete the student's rows. Every statement that starts after it commits records nothing and returns no notes. A write or note read that began before the withdrawal commits can still finish after it: it can leave a late counter row, and notes already sent to the AI provider cannot be recalled. There is no sweep and no lock; I do not claim erase is race-free. `forget` can be run again to remove a late row, and the policy says so. The real fix needs per-student ordering in the database (a transaction or advisory lock through the door) and a real-database test with a held writer; that is left open for Edward and the coordinator. Counters count looks, and a retried request is a real extra look; hint rows are deduplicated by their unique key.

## 5. The "only cite dated history on record" rule

1. **Eligibility.** The only past that reaches a model is Edward's dated notes, and only in the reword step: each carries a tag and his session date (`[n1] Edward, 2026-11-09: ...`). Nothing else about the past exists in any prompt. Course or grade never becomes a claim of what was covered (design 6.3 rule 4).
2. **The rule given to the rewriter**: the notes are for tone only; never mention earlier sessions, the notes, or what the student usually does. (Stricter than the design's "cite by tag and date", which needs the phase 2 `cite` field.)
3. **Code guard** on the reworded hint: cross-session recall phrasing ("last time", "last session", "last week", "last lesson", "yesterday", "the other day", "we did", "we talked", "we went over", "remember when", "as before", "like before", "previously", "you tend to", and "you always/usually/often" unless followed by a rule-like verb such as "need", "have to", "change", "flip") makes the rewrite fall back to the original hint, label `unsupported_history_claim`. A table test covers phrases that must and must not fire ("check the sign again" must not). This is a heuristic with false negatives; the eval counts how often the rewriter produced such phrasing and the report does not claim zero misses. Because the original hint is always the fallback, a false positive costs only the personalisation.

`/api/ask`, `/api/consult` and the live voice's own words are free text with no notes in this slice, so there is nothing to guard there yet.

## 6. Admin commands (`scripts/codes`)

```
consent CODE                       show consent state (who, how, version, when)
consent --list                     every code: memory on or off, version (no counts)
consent CODE --by parent|adult [--form-date YYYY-MM-DD]     record a grant from a signed form (recorded_via admin)
consent CODE --withdraw
note add CODE "text" [--on YYYY-MM-DD] [--pin]     refused when the code has no current consent
note list CODE        note delete CODE ID
export CODE           the student's whole record as JSON on stdout (PIPA s. 23); keyed by log id, never the code
forget CODE --yes [--including-consent-log]     withdraws and deletes attempts, hints and notes in one statement (and removes the consent log if asked); prints the counts; safe to run again
forget-inactive [--months 12] [--yes]           dry run by default; lists or deletes record data for codes unused for N months
```

Each prints counts and ids only. `forget-inactive` exists because the consent text promises that unused records are deleted after 12 months; a promise with no code behind it would not be meaningful consent. Whether 12 months is right, and the interaction of deletion with PIPA s. 35(1) (keep decision data one year), is an open legal question (design 8.3). The consent log is kept by default after an erase as a minimal audit trail (granted or withdrawn, when, which version and text hash, no content); the policy says so, and `--including-consent-log` removes it for anyone who objects.

## 7. iPad

New files under `ios/PencilTutor/Memory/` (`MemoryStore`, `MemoryConsentView`, `MemoryRecordView`), a `memory...` set of methods on `TutorClient` with protocol-extension defaults (so a branch that adds another `TutorClient` conformer still compiles), implementations in `HTTPTutorClient` and `ScriptedTutorClient`.

- Settings gets a **Memory** section: "Tutor memory: On since <date> / Off / Not available". Rows: "Turn on memory" (opens consent) or "What the tutor remembers" (opens the record). Hidden when the server is silent or says off with no record.
- `RootView` presents the consent sheet once when the account is ready, the feature is on, no decision is on record, and this code has not been offered before (UserDefaults key by code hash). This is Edward's explicit requirement ("offered once, skippable, reachable from Settings"); review 1 suggested dropping the offer and I am keeping it on his instruction. `ProblemListView` is not edited (the course picker branch rewrites it).
- Consent screen: scrollable, headings and short paragraphs from the server's notice, the two-choice attestation, two equal buttons, "Read the full policy" link. Record screen: status, counts, up to 10 recent problems (prompt text from the bundled bank, id otherwise), "Turn off memory" and "Erase what the tutor remembers" with confirmation dialogs.
- Calm UI: system type scaling, nothing in `lineLimit(1)`, every control at least 44 pt, text wraps rather than truncates, usable portrait and landscape. No streaks, points, or nudges to opt in.
- Scripted launch: `--scripted-client` keeps today's behaviour (feature off, no offer) unless `--memory-on` is added; `--offer-memory` also allows the once-only sheet. Existing UI tests are unaffected.
- Scripted runs have no student code, so the "offered once" key uses the stand-in name `scripted` and a throwaway UserDefaults domain (`com.edwardtran.penciltutor.scripted`) emptied at every launch. Before this, the key was nil in a scripted run and the sheet never appeared (the CI failure at `MemoryScreensUITests.swift:67`, 2026-11-14). A rerun on the iPad therefore sees the offer again.
- Debug builds only (Release builds read them as false): `--memory-agreed` starts the scripted tutor with an agreement on record, and `--show-memory-record` opens "What the tutor remembers" by itself once the list appears. Both are for screenshots on the iPad; `--ui-snapshots "portrait@6,landscape@12"` (see `UISnapshot.swift`) takes the pictures.
- No change to StoreKit or code-entry files.

## 8. Tests

Server (Node test runner; the Postgres tests run on GitHub CI and are skipped on the laptop unless `PT_PGLITE=1`, the convention `iap-subscription` already uses). Fakes are small stubs with fixed answers; there is no in-memory twin of the database (review 1); SQL is exercised on PGlite.

- **Detection independence across consecutive looks** (the test that carries the premise): a consenting student with notes and a student with none each make three successive looks through the real handler with a mock model, feeding each response's `hint_written` back as history exactly as the app does (`TutorSession.swift:1051`). The detection prompt, system text, image and schema must be equal for both students on every look; the notes appear only in the second call; `action`, `line` and `hint_written` of every response equal the detection result even when the rewriter returns nonsense, times out, or tries to change them.
- Flag off: no statement and no second call, and the JSON body equals today's apart from `request_id` and `latency_ms`. No consent (flag on): no second call, same body comparison, one insert-nothing statement.
- Spoken rewriter: falls back to the original spoken hint on parse failure, timeout, leak of `final_answer`, recall phrase; guard table of phrases that must and must not fire; notes never appear in any log line.
- Watch with a store stub: consent on records an attempt and a hint; withdrawal between read and write records nothing; store timeout or error degrades to today's behaviour with the right label and a 200; question recording on ask and consult.
- Endpoints: status shape; feature off with and without an existing record; attestation required; stale notice version 409; consent then withdraw then erase; withdraw and erase still work with the flag off; unauthenticated privacy page; policy copy equals `docs/`.
- **Notice pinned by hash**: a test holds the SHA-256 of the notice text for the current `NOTICE_VERSION`; changing the words without bumping the version fails. The grant row stores the hash, so the exact words shown are recoverable from git at that version and checkable against the stored hash. (Replaces the keyword test.)
- No-content logging: across all of the above, no log line contains note text, a code, or hint text.
- **Real SQL on PGlite (Postgres compiled to WebAssembly, in-process, CI only)**: migration 004 applies twice, latest-consent-wins, notes read returns at most 3 pinned first, upserts are idempotent for hints, look write refused without consent, erase counts, sequential withdraw-then-write records nothing and returns no notes, withdraw-plus-delete leaves zero rows when nothing is in flight (the in-flight race is not testable on PGlite and is an open item), `forget-inactive`, and a timing log on a table padded to a few thousand rows (bounded queries and measured time; no planner assertion).

iOS: unit tests for the store's state machine (feature off hides everything, attestation required, version mismatch re-fetches, withdraw with erase, offer-once policy) with a fake client; UI test `MemoryScreensUITests` driving the scripted client through Settings, consent, record and withdrawal, with `XCUIScreen.main.screenshot()` attachments in both orientations, run on the iPad.

Not tested here, and said so: Neon timing and concurrent overlap on the real database (PGlite cannot show either), and an iPad pass against the deployed server with real handwriting. Both wait for Edward's rollout step 6.

## 9. Eval gate (design section 7), reshaped

Detection and the written hint are the same for every student, proven by the section 8 test across consecutive looks; I do not claim more than that (not identical delivery timing, not semantic correctness of a reword). What can go wrong is the spoken reword, so that is what is evaluated, with a pass rule fixed before the run.

`server/eval/run-eval.ts` gets `--reword notes,priming`: for each saved page whose detection result is an interrupt, run `rewordSpoken` with a synthetic record (`notes`: two realistic tone notes; `priming`: notes claiming a habit such as dropping a minus sign) and save every original spoken hint, reworded hint, and fallback label. Model `gpt-6-luna`, 2 repetitions over the 15 wrong pages (about 30 detection calls and 60 reword calls, a few cents; keys load exec-only through the Vercel CLI, never read or printed). The existing runner always sends empty history (`run-eval.ts:130`); that does not matter here because the reword step takes no history and detection is untouched, and the consecutive-look property is tested in section 8 with the app's real history rule.

**Pass rule (a failure blocks release of the reword step; the fix is the rewriter's prompt, then a rerun):**

1. I read every accepted rewrite next to its original and its page's known error type. Every one must keep the same diagnosed slip, add no corrected value or corrected line, and contain no reference to earlier sessions or to the notes. Counts and the reasoning are written into `server/eval/results/memory-reword.md`.
2. Zero rewrites that pass the code checks but fail the reading (that would be a guard hole, reported with the example).
3. Fallback rate by reason and the recall-phrase rate before the guard, reported with coverage ("N interrupts of M looks"); a high fallback rate is a finding, not a failure.
4. Second-call latency and cost reported (the extra delay is an estimate until measured).

Caveats: synthetic fonts, not real handwriting; fifteen pages is a smoke test, not statistics; with this few students no learning effect is measured or claimed.

## 10. Rollout order (for Edward or the coordinator)

1. Merge `tutor-memory`. Do not deploy yet.
2. `server/scripts/codes migrate` (applies `004`, additive; also `003` if that branch merged first).
3. Deploy the server. `STUDENT_RECORD` unset: nothing changes for anyone.
4. Ship the app build. It shows no memory controls while the server is silent or off.
5. Before any family is asked: lawyer hour on the consent text and `docs/privacy-policy.md`; fill the contact line in the policy.
6. Set `STUDENT_RECORD=on` in Vercel production and redeploy. Still nobody is remembered until a parent agrees. Then the deployed-server checks: an iPad pass with real handwriting, withdrawal and erase, and the read/write timings in the logs.
7. Per family: in-app consent, or `scripts/codes consent CODE --by parent --form-date ...` after a signed form.

## 11. Verification I can and cannot do

Can: unit and SQL tests on CI, the detection-independence test, the reword eval, on-device screenshots. Cannot: the lawfulness of the text, whether a child can tell what they are agreeing to (the OPC suggests testing comprehension with real users; not done), real-handwriting behaviour, anything on the production database (migration deliberately not run), processors' retention terms beyond what is written in the policy's open items.

## 12. Open objections from review 3, left for Edward and the coordinator

1. **Erase race** (review 3, section 1 and traps): late writes can survive an erase; "elapsed time is not proof that earlier writes finished." Needs per-student ordering in the database and a real-database test with a held writer.
2. **Personalised wording reaches live speech and `/api/consult`** (reviewer: "personalised wording remaining in live conversation after withdrawal"; the loop `TutorSession.swift:694` to `LiveVoice.swift:268` to `consult.ts:72`). Not built around; the rewrite switch is off by default for this reason.
3. **Rewrite gate can pass if every rewrite falls back**; the reviewer wants demonstrated useful accepted rewrites and a test of the model configuration actually enabled (advanced problems use a different watch model, `config.ts:35`). The eval reports the accepted count; the advanced path is not tested.
4. **Delayed responses on the iPad, live speech then consult, and withdrawal during an active session** are not exercised by mocked handler calls; need an iPad pass on the deployed server (rollout step 6).
5. **"Eight words" for the written hint is a prompt instruction, not enforced** (`policy.ts:29` allows 120 characters).
6. Vendor retention terms and the legal conclusions are not established by repository evidence (already listed in the policy and the design).

## 12b. Review notes and where I overruled

Review 1 (REDO) and review 2 (REDO) points and what happened: the premise was rebuilt twice (sections 4 and 9); neutral-hint substitution, in-memory twin, notice keyword test, 50-row list, lifetime counts, written-hint rewriting, and the blanket exemption from regression checks are gone; the notice is pinned by hash; management survives the flag; the privacy policy is reconciled with the design; erase now withdraws, deletes and sweeps; "Release builds do not log words" was wrong and is corrected (the device session log records the written hint, up to 8 words, and Export log shares it; spoken hints are logged only in Debug, `TutorSession.swift:1046-1047`); a `TutorSession` is created per problem screen (`ProblemScreen.swift:22`), so an attempt is one opening of a problem. **Overruled, with reason:** (a) removing the auto-offer, offer-once storage and the second grant path (review 1): Edward's instruction names all three. (b) Review 2's "retire the exemption" is met by test rather than by re-running the old no-brief eval: with detector inputs identical by construction the eval would only measure model noise, and I say what is proven (inputs) and what is not (delivery timing, reword semantics).

Questions for review 3:

1. Is spoken-hint-only rewording after detection, with fallback to the original spoken hint, now the smallest design that meets the goal, or should the reword step be dropped from this slice (notes stored and shown to Edward only)?
2. Is withdraw, delete, sweep an acceptable answer to the erase race given one statement per call?
3. Anything else to cut?
