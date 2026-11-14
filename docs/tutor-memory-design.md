# Pencil Tutor: the student memory layer (design)

Written 2026-11-14. Owner: Edward. Personal side project (not BLI work).

**Status (2026-11-14, later the same day): phase 1 is built on branch `tutor-memory`, as an OPT-IN, and changed in four ways from this document.** (1) Memory is off for everyone until a parent or guardian (or an adult student) agrees; the consent record, text and policy are in `docs/tutor-memory-plan.md` and `docs/privacy-policy.md`. (2) Edward's notes never enter the watch call that decides whether to interrupt; they can only reword the SPOKEN hint after that decision, behind a separate switch (three plan reviews, section 12 of the plan, lists what stayed open). (3) No `cite` field and no shadow mode; a hint may not refer to the past at all. (4) The per-skill record is deferred to phase 2. The rest of this document is the original design and is unchanged.

Plain words first, the official term once at the end of a section where there is one.

## 1. The answer in one screen

**What it is.** A small, structured record of each student, kept in the Neon database the server already uses, that a tutor with Edward's voice reads before it speaks. It holds five kinds of fact: where the student stands on each curriculum skill, which mistakes keep coming back, which kind of hint actually unsticks them, a short recap of recent sessions, and the notes Edward himself writes after a human session. A compact brief (300 tokens at most) is built from that record and put in front of the model. The tutor may mention the past only through items that are in the brief, each with its date. (Official terms: a student model with knowledge tracing, a misconception library, and a provenance-checked, bounded context block.)

**Build or adopt: build, thin, on Neon.** About ten small additive tables (five in Phase 1, the rest as later phases need them) and one module. Borrow ideas from Letta, Mem0 and Graphiti; adopt none of them. Reasons, with numbers, are in section 3.

**Smallest useful slice (section 11, Phase 1).** Edward's own notes about a student, injected into the tutor's prompt behind an opt-in switch, plus silent recording of the events the later phases need (they cannot be backfilled), plus delete and export. No new model behaviour is trusted yet. About 3 to 4 working days (an estimate, not a measurement).

**Cost.** About US$0.02 to 0.06 per student per month on the cheap high-school model at 4 to 8 counted hours, against a current variable cost of US$4.68 to 7.36 at 8 hours (`docs/plan.md`, amendment 13). On the frontier model used for college-level problems the same additions cost about 20 times more, roughly US$0.5 to 1.0. The real cost is Edward's review time, not model dollars (section 9).

**Biggest risk.** A wrong inference that is stored and then repeated back to a child as fact (a mistake mis-tagged as a "habit", a hint credited with a fix it did not cause). The design answers it with evidence thresholds, hedged wording, the student's own "what do you remember about me" screen, and Edward's review. The second risk is legal, not technical: profiling minors without a clean consent record (section 8).

### What was checked and what was not

| item | status |
|---|---|
| Existing server code, plan amendments, migrations, banks (read) | verified by reading; file:line given |
| BLI Memory design docs (read, ideas only) | verified by reading |
| Star counts, licences, last push, latest release for the memory projects | verified with `gh api` on 2026-11-14 |
| Postgres support claims for Mem0, Letta, Graphiti, Zep, LangMem | verified from vendor docs via search snippets; Cognee, MemOS, Supermemory not checked |
| Learning-science effect sizes quoted | verified against abstracts or publisher pages, listed in section 13 |
| Canadian law | statute text of BC PIPA read; OPC pages read; **not legal advice, and several points are open questions for a BC privacy lawyer** |
| All mastery formulas and thresholds | **untested starting guesses**; they are logged so they can be calibrated, section 6.4 |
| Costs of looks per hour, brief size, rows per month | **assumptions** (stated) until real sessions are logged |

## 2. What exists today (so the design fits it)

- **`server/lib/students-memory.ts` is not student memory.** It is `MemoryStudentStore`, an in-memory test double of the usage meter (`server/lib/students-memory.ts:17`; the real store is `PgStudentStore`, `server/lib/students.ts:214`). It stores codes and monthly seconds. The new layer must not reuse that name. Proposed home: `server/lib/record/` ("student record"), so nobody confuses it with the meter.
- **The server is stateless about the student's work.** `/api/watch` takes a page picture, a line list and up to 10 earlier decisions sent by the app (`server/lib/watch.ts:19`, `:51`; `MAX_HISTORY = 10`, `server/lib/policy.ts:55`). Nothing about a hint, a line or a problem outcome is written down. The only per-student writes are the usage counters (`usage_months`, `server/db/migrations/001_students.sql`).
- **Students are a code and a number.** `students(id, code, ...)`, no name. All logs carry `student` = an 8-character hash of the code (`server/lib/students.ts:28`). The memory layer keeps that property.
- **One door to Postgres.** Raw SQL through `Db.query` (`server/lib/db.ts`), 5 second timeout (`:22`), errors reduced to a label. Measured 5 to 23 ms per query warm, 53 to 82 ms for the first query after Neon's free compute sleeps (`docs/plan.md`, Storage paragraph, amendment 13).
- **Prompts.** `WATCH_POLICY` (`policy.ts:8`) sets the stance: wait by default, interrupt only on a clear, consequential wrong step on a finished line, hint the kind of slip, never the answer. `ASK_POLICY` is `policy.ts:98`, the live voice prompt `:114`, the page reader `:162`. The reference solution is injected per problem by `referenceBlock` (`:58`).
- **A guard pattern already exists** that this design copies: `finalizeDecision` turns a hint that contains the final answer into a `wait` with the label `hint_reveals_answer` (`server/lib/decision.ts:40`).
- **There is no hint ladder yet.** One hint per interrupt, plus "do not repeat a hint for the same line unless rewritten" in the prompt.
- **There is no "problem solved" signal.** "Check my work" is just a manual look through `/api/watch` (`ios/PencilTutor/Session/TutorSession.swift:357`). The server cannot tell "finished and right" from "nothing wrong so far". Section 6 adds that signal.
- **Problems carry no curriculum standard.** Today's `shared/problems.json` has `id`, `source`, `prompt_*`, `worked_solution`, `final_answer`, `level` and nothing else. The per-course banks being built (seen in the calculus, linear algebra and discrete worktrees; `shared/courses/` does not exist on `main` yet) map official outline topics to problem ids in each course README, as markdown tables, e.g. "Chain rule: c1-29 to c1-31" in `shared/courses/calculus-1/README.md`. That mapping is the raw material for skill keys; it is not yet machine-readable.
- **Audio and pictures are not stored server-side.** `/api/ask` decodes the audio in memory and passes it to transcription (`server/lib/ask.ts:45`); page pictures are validated and passed to the model. Only the iPad Debug build keeps picture copies, locally.

## 3. Research

### 3.1 What BLI Memory already learned (read-only; ideas, not code)

Sources read: `bli-cockpit/docs/architecture/agent-memory.md` (the design), `memory-exam.md`, `memory-spend.md`, `people-models.md`, `hit-ledger.md`, and `BLI/BLI-MEMORY-HANDOFF-2026-09-06.md`.

Patterns that transfer:

1. **Every claim carries its evidence.** People models store each field as `{ value, status, evidence[], as_of, n }`, and a field with nothing behind it says why it is empty (`people-models.md`). Here: every brief item has a tag, a date and a count; an item without them is not eligible for the brief.
2. **History is the table; superseded and forgotten are different.** An update inserts the new version and points the old one at it; "forgotten" means never surface again; recall indexes are partial on live rows so a forgotten row is unreachable by construction. Here: misconceptions go `active -> fading -> resolved` with dates (never overwritten). One deliberate difference: BLI never deletes; for children, "forget" must be a real delete (section 8).
3. **Learned time and valid time.** `created_at`, `valid_at`, `invalid_at` (bi-temporal facts, as in Zep's Graphiti paper). Here: `first_seen_at`, `last_seen_at`, `resolved_at`.
4. **Summaries sit on top of originals and keep specifics by construction.** The nightly dream writes a summary beside the originals, never merges; numbers, dates and ids are extracted by fixed rules and a summary that drops one is refused. Here: the session recap is rendered from structured facts by a template, so no model can paraphrase a date wrong.
5. **A model judges, a closed vocabulary decides, a bar gates.** Memory labels are yes/no or closed-list questions acted on at 0.8; below the bar the answer is "none", never a guess. Here: the misconception tag is a closed list per skill plus `other`, acted on only above a confidence bar.
6. **Surprise and repetition decide what sticks.** Corrections and repeated subjects are weighted up in recall; low-value items rank last but are never hidden. Here: a mistake that repeats outranks one seen once.
7. **Log the recall verdict, with reasons not bodies.** `win | loss | noise` plus a one-line reason, never prompts or memory text. Here: Edward's review verdicts use the same shape (section 7).
8. **Test the memory on a schedule and report coverage with the score.** The nightly exam reports "33 of 38 graded, 38 of 40 planned". Here: the eval report always shows coverage.
9. **Taxonomy health check.** The hit ledger says: if the top 10 patterns cover under 70% of weight, the taxonomy is wrong. Here: if `other` is more than about 30% of misconception tags, the catalog is wrong, and the report says so.
10. **Spend by operation, with a breaker rather than a cap.** Every model call is tagged by what it was for. Here: tag `memory_write`, `memory_eval`, separate from `watch` and `ask`.
11. **Sensitive human flags go to one person, rate-limited, without the text.** The check-in lane tells Edward, at most once per three days per person, and never quotes. Here: "this student may be struggling" goes to Edward only.
12. **The extractor decides the ceiling.** BLI measured that a distilled sentence has already lost the capitals, the "again", the language; the label's yield is bounded by extraction. Here: record structured fields at the moment of the decision (inside the watch call), never summarise a transcript afterwards.
13. **Do not call a relabel a win.** The handoff doc's hardest lesson: bad relevance labels made a 45% versus 85% benchmark meaningless; after reviewed labels BLI was already 23/28 before the change and 24/28 after. Here: evals use fixed fixtures and a blind grader, and report what did not move.
14. **Pin the live definition, not the migration file.** A function was silently replaced from an older body and lost its index cast for five days (BLI-10448). Here: the SQL that does the mastery arithmetic is tested against a real Postgres (the repo already has `test/db.integration.test.ts`).

Does not transfer: pgvector hybrid search, halfvec indexes, container tags, the company-wide dream, extraction from long agent transcripts. A student has hundreds of structured rows, not 236,000 free-text memories, so no semantic search is needed in the first phases.

### 3.2 Open-source memory layers

Counts from `gh api` on 2026-11-14.

| project | stars | licence | last push | latest release | how it runs | Postgres |
|---|---:|---|---|---|---|---|
| Mem0 | 68,951 | Apache-2.0 | 2026-11-06 | ts-v3.3.1 (2026-09-25) | library or self-hosted server, plus a hosted platform | pgvector is a supported vector store; the TypeScript OSS build lacks graph memory and reranking (Python only), per its configuration doc |
| Graphiti (Zep's engine) | 32,805 | Apache-2.0 | 2026-11-14 | v0.31.2 (2026-10-20) | Python library | **no**: needs Neo4j, FalkorDB or Neptune (Kuzu driver deprecated) |
| Zep | 5,007 | Apache-2.0 (examples repo) | 2026-11-13 | zep-ingest-v0.4.0 | commercial hosted; Community Edition **deprecated and unsupported** | n/a |
| Letta (ex-MemGPT) | 25,436 | Apache-2.0 | 2026-10-18 | 0.16.8 (2026-05-14) | self-hosted Docker server (FastAPI) that owns the agent loop | requires Postgres with pgvector (`LETTA_PG_URI`) |
| LangMem | 1,767 | MIT | 2026-11-13 | no tagged release | Python library on LangGraph | via LangGraph `AsyncPostgresStore` |
| Cognee | 33,306 | Apache-2.0 | 2026-11-14 | v1.6.8 (2026-11-12) | Python | not checked |
| MemOS | 12,399 | Apache-2.0 | 2026-11-11 | v2.0.36 | Python | not checked |
| Supermemory | 31,616 | MIT | 2026-11-13 | server-v0.0.9 | hosted plus local | not checked; BLI retired it on 2026-11-04 |
| Hindsight | 60,992 | MIT | 2026-11-14 | v1.2.1 | one Docker image with embedded Postgres | claim is the vendor's own, not checked |

Notes: Mem0's hosted price list changed at least once in the last two months (a Starter at US$19 and Pro at US$249 are listed on one page and gone from an archived copy; a trade-press piece says Free and Custom only), so any vendor price here is soft. A third party quotes Mem0 as saying its recommended models cost US$3.55 to 5.34 per 1,000 adds. The best-known comparison article (hindsight.vectorize.io, 2026-08-11) is written by a vendor in the list and says so; none of its benchmark numbers are used here.

**Recommendation: build, thin.** In order of weight:

1. **Wrong shape.** These tools turn conversation into free-text "facts" with a language model on every add. Pencil Tutor's memory is numeric and keyed by curriculum skill (mastery, misconception counts, hint fix rates). None of the projects models that, so the data model still has to be built, and then fought against a tool's own schema.
2. **Wrong cost shape.** At US$3.55 to 5.34 per 1,000 adds, a memory write costs about 22 to 33 times a whole page look on the cheap model (US$0.00016, `docs/plan.md` amendment 14). The events here are structured and arrive from decisions the server already makes; recording them costs one SQL statement.
3. **Wrong runtime.** The server is short-lived Vercel Functions in TypeScript on Neon. Letta is an always-on server that owns the agent loop; Graphiti needs a graph database; LangMem, Cognee, MemOS are Python. Only Mem0's TypeScript build fits, and it still brings its own tables and an LLM in the write path.
4. **A new vendor holding children's profiles.** A hosted memory service is one more processor of minors' data across the border, with its own deletion semantics to verify (section 8). Building on Neon adds none.
5. **Provenance is the product rule.** "Only cite history that exists, with its date" is far easier to enforce over rows you own than over a vendor's merged, paraphrased memories.

**What to borrow.** Letta's core-memory block (a small always-in-context block: our brief). Graphiti's valid-from and valid-to on facts. Mem0's add / update / delete / no-op reconciliation verbs when a new observation meets an old one. LangMem's split into semantic, episodic and procedural memory (ours: skill and misconception state, session recaps, hint statistics and tutor rules).

**When to revisit.** If Edward later wants free-text recall ("what did we say about her fraction anxiety in October"), add pgvector to the same Neon database (Phase 6), not a new service. Re-evaluate adoption only if the product grows beyond roughly 500 students or needs cross-device agent memory.

## 4. Learning science that decides what is stored

Short, with the design consequence beside each. Full citations in section 13.

| finding | source | what it changes here |
|---|---|---|
| Human tutoring d = 0.79, intelligent tutoring systems d = 0.76, step-based tutoring 0.76, answer-based 0.31; the "two sigma" figure from Bloom (1984) is much larger than later studies find | VanLehn 2011; Bloom 1984 | The target is the step-level behaviour the app already has, not a mythical 2 sigma. The memory should make step feedback better, not replace it. Tutoring programs pool at 0.37 SD (Nickow, Oreopoulos, Quan 2020), a more modest realistic anchor. |
| Expert tutors are Intelligent, Nurturing, Socratic, Progressive, Indirect, Reflective, Encouraging (INSPIRE); feedback after errors is indirect to reduce evaluative pressure | Lepper and Woolverton 2002 | Memory should shape tone and hint indirectness per student ("start with what is right"), and must never turn into "you always make this mistake". |
| Engagement ranks Interactive > Constructive > Active > Passive | Chi and Wylie 2014 (ICAP) | A remembered fact should trigger a question the student answers ("which sign changes here?"), not a recital. Recaps are two sentences, then a prompt to attempt. |
| Unguarded GPT-4 in a high school maths class raised practice scores and then lowered exam scores by 17% (GPT Base); a hint-only tutor with teacher-written notes largely removed the harm | Bastani et al., PNAS 2025 | Memory must never make answer-giving easier. The brief carries no solutions; the existing `hint_reveals_answer` guard stays; hint escalation is tutor-driven, never "show me more" driven. |
| Students skip through hint levels: in one study they spent under 1 second on 68% of hints before reaching the bottom-out hint | Aleven et al. (help-seeking research, CMU) | The ladder escalates only after the student has re-attempted the same line (rung rule, section 6). |
| Knowledge tracing: Bayesian KT (Corbett and Anderson 1995) needs fitted guess, slip, learn and prior per skill; deep KT (Piech et al. 2015) needs large data; on moderate data, logistic models with the right features lead (Gervet et al. 2020); Elo-style ratings are simple, robust and need no fitting (Pelanek 2016) | as cited | With a handful of students and no history, fitting is impossible. Start with an Elo-style estimate, log every prediction, and move to a logistic model once there is enough data to tell. |
| Practice testing and distributed practice rate "high utility"; interleaved practice is "moderate" in the same review; spacing helps across 839 assessments in 317 experiments | Dunlosky et al. 2013; Cepeda et al. 2006; Roediger and Karpicke 2006 | Store when each skill was last attempted unaided and when it is next due; the picker can offer a due skill. |
| In 54 seventh-grade classes over 4 months, interleaved assignments scored 61% versus 38% for blocked on a surprise test a month later (d = 0.83) | Rohrer et al. 2020 | Interleaving is worth building into the problem picker (Phase 4), using the due list. |
| Students' errors are systematic procedural bugs, not random slips | Brown and Burton 1978 (BUGGY), Brown and VanLehn 1980 | A misconception library keyed by skill, with evidence counts, is the right unit of memory for "knows how you get stuck". |
| Scaffolding means the tutor takes over what the learner cannot yet do and fades as competence grows | Wood, Bruner and Ross 1976 | Hint rung starts where the record says the student needs it and fades as a misconception goes `fading`. |

Honest limit: most of these results come from classrooms or large tutoring systems. Nothing here proves that this particular memory layer improves outcomes; it can be built so that it is measured (section 7), not assumed.

## 5. What a good human tutor knows and does, mapped to data

| a good tutor... | stored as | changes the tutor's behaviour by... |
|---|---|---|
| knows where you stand on each topic | `skill_state` (one row per student per skill: attempts, unaided successes, an ability estimate, last seen, next due) | choosing the hint rung, wording ("this is solid for you now"), and suggesting what to practise |
| remembers the mistakes you keep making | `student_misconception` (evidence count, first and last seen, state) from a per-skill catalog | naming the habit in the hint with its date, watching that line more carefully **without lowering the bar to interrupt** (see risk below) |
| knows what kind of help works for you | `hint_stats` (rung and channel by outcome) | starting at the rung that has worked, using written-only if that is enough |
| remembers last time | `session_summary` (structured facts, rendered by template) | a two-sentence recap when a session opens, followed by a question |
| knows when to bring something back | `skill_state.due_at` | offering a due skill in the picker (Phase 4) |
| knows you as a person | `human_note` written by Edward; a few explicit preferences set by the student | tone, pace, language, goals |
| never invents shared history | provenance rules (section 6.3) | the tutor cites only tagged, dated items; grade-level guesses are banned |

**Priming risk, stated plainly.** If the tutor is told "this student often drops a sign", it may start seeing dropped signs that are not there. The existing stance, "a false alarm is the worst failure", is the product's most valuable property (30/30 exact lines, 0/30 false alarms on the synthetic set, `docs/plan.md` amendment 14). So in v1 the brief **may change what the hint says, never whether the tutor interrupts**: the interrupt rule in `WATCH_POLICY` stays untouched, and the brief says so. Letting memory raise sensitivity is a later, eval-gated change (section 7).

## 6. Design

### 6.1 Skills: the key everything hangs on

A **skill key** is a short stable string per curriculum skill, namespaced by course, e.g. `calculus-1:chain-rule`, `bc-math-9:linear-equations-two-step`. It is the join between a problem, a mastery row, a misconception and a due date.

Contract for the banks (a small request to the course branches, not code in this repo yet):

- Each `shared/courses/<course>/` gets `skills.json`: `[{ key, title, standard_ref, prereqs: [key], misconceptions: [{ key, name, example_wrong_step, hint_seed }] }]`. `standard_ref` is the official outline or curriculum line the README already cites.
- Each problem in `problems.json` gets `skills: [key, ...]` (first is primary).
- The existing `verify.py`-style check fails the bank if a problem has no valid skill, if a skill has no problem, or if a misconception references a missing skill. The README tables already hold the data (outline topic to id range), so conversion is mechanical.
- The server loads `skills.json` next to the problems (same copy-into-`server/data/` rule as `problems.json`; a test fails if the copies drift).

Misconceptions authored this way are a **catalog** (what we know exists), seeded by Edward and by the model-assisted drafting of common errors per skill. The model may also tag a mistake as `other` with a short label; `other` labels are queued for Edward to promote into the catalog or discard. This is how the library grows without the model inventing categories on its own.

### 6.2 Data model (Postgres, additive migrations only)

Migration `003_student_record.sql` onwards. Every table references `students(id) on delete cascade`, so deleting a student deletes their record. Every statement is `create ... if not exists`, nothing dropped or rewritten, matching `001` and `002`. Illustrative columns; exact types settle in the build.

**`student_profile`** (one row per student; created lazily)
`student_id pk`, `memory_enabled bool default false`, `courses text[]`, `prefs jsonb` (explicit settings only: `hint_channel`, `language`, `pace`, each with `set_by` and `set_at`), `brief_global text`, `brief_version int`, `brief_tokens int`, `brief_built_at`, `created_at`.
Why: the always-on part of the brief is **pre-built** at write time, so the hot read is one primary-key lookup.

**`consent_events`** (append-only)
`id`, `student_id`, `purpose` (`core_service | memory | aggregate_stats | flag_upload`), `granted bool`, `by` (`parent | student | edward_recorded`), `notice_version`, `at`.
Why: separate opt-ins per optional feature, and evidence of who agreed to what. `memory_enabled` is true only when the latest `memory` event is a grant.

**`skill_state`** (pk `student_id, skill_key`)
`attempts int`, `unaided int`, `assisted int`, `failed int`, `theta real` (ability, log-odds), `n_eff real` (evidence weight), `first_seen_at`, `last_seen_at`, `last_unaided_at`, `interval_days real`, `due_at`, `updated_at`.
Totals are updated in place by one atomic `insert ... on conflict do update` statement; nothing is recounted from events.

**`problem_stats`** (pk `problem_id`; population-level, no student id)
`attempts int`, `unaided int`, `mean_hint_rung real`, `difficulty real`. Elo item difficulty; starts from authored order and level and only becomes informative after roughly 30 attempts per problem. With a few students it stays near its prior, and the doc says so.

**`attempt`** (append-only fact table)
`id`, `student_id`, `problem_id`, `session_id`, `started_at`, `ended_at`, `counted_seconds`, `outcome` (`open | solved_unaided | solved_with_hint | gave_up | left`), `looks int`, `interrupts int`, `asks int`, `checks int`, `max_rung smallint`, `p_before real` (the predicted chance of an unaided success, logged for calibration).
Unique `(student_id, session_id, problem_id, started_at)`. Rows are small (about 100 bytes).

**`hint_event`** (append-only)
`id`, `student_id`, `attempt_id`, `at`, `line`, `drawing_revision`, `rung smallint`, `channel` (`written | spoken | both`), `misconception_key` (null if unknown), `tag_confidence real`, `resolution` (`fixed_probable | repeated | none_seen | unknown`), `seconds_to_resolution`.
Unique `(attempt_id, drawing_revision, line)` so a retried request does not double-count. No hint text, no page content, no student words.

**`student_misconception`** (pk `student_id, misconception_key`)
`skill_key`, `evidence_count int`, `attempts_seen int` (distinct attempts it appeared in), `first_seen_at`, `last_seen_at`, `last_attempt_id`, `opportunities int` (closed attempts on the skill since first seen), `clean_streak int`, `status` (`candidate | active | fading | resolved | overridden`), `status_since`, `overridden_by_note_id`.
`candidate` = seen once, never surfaced. `active` = `evidence_count >= 2` and `attempts_seen >= 2`. `fading` = 3 consecutive opportunities without it. `resolved` = 5 or more opportunities clean and at least 14 days since last seen. `overridden` = an Edward note retired it. All thresholds are starting guesses.

**`hint_stats`** (pk `student_id, rung, channel`)
`n int`, `fixed int`, `seconds_sum`. Shown to the tutor as "what works" only at `n >= 8` per cell and a gap of at least 0.2 between cells. Never presented as proof.

**`session_summary`** (pk `student_id, session_id`)
`started_at`, `ended_at`, `counted_seconds`, `problems int`, `solved_unaided int`, `facts jsonb` (at most 5 items: `{kind, skill_key, misconception_key, attempt_id}`), `recap text` (rendered from `facts` by a template, at most 280 characters).

**`human_note`** (Edward only)
`id`, `student_id`, `session_on date` (the date of the human session), `kind` (`observation | goal | preference | correction | alert`), `skill_keys text[]`, `body text` (at most 500 characters), `pinned bool`, `expires_on date null`, `created_at`.
Highest-trust input. A `correction` can retire an inferred misconception (`overridden`). Written through an admin command (extension of `scripts/codes`), never through the app API. **Write each note as if the student or parent will read it**, because they can ask for it (section 8).

**`review_flag`** (Edward's queue)
`id`, `student_id`, `attempt_id`, `raised_by` (`auto | edward | student`), `reason` (closed list: `hint_repeated_no_fix`, `answer_leak_blocked`, `unsupported_history_blocked`, `wrong_flag`, `missed_error`, `tone`, `other`), `status`, `verdict` (`win | loss | noise`), `outcome` (`fixture | rule | nothing`), `created_at`, `resolved_at`.
Stores ids and labels, never page content.

**Index list** (small tables; indexes keep each read a bounded lookup as data grows):

| table | indexes |
|---|---|
| `student_profile` | pk |
| `skill_state` | pk `(student_id, skill_key)`; `(student_id, due_at) where attempts > 0` |
| `student_misconception` | pk `(student_id, misconception_key)`; `(student_id, skill_key, last_seen_at desc) where status in ('active','fading','candidate')` |
| `attempt` | pk; `(student_id, started_at desc)`; `(student_id) where outcome = 'open'` |
| `hint_event` | pk; unique `(attempt_id, drawing_revision, line)`; `(student_id, at desc)` |
| `session_summary` | pk; `(student_id, ended_at desc)` |
| `human_note` | `(student_id, created_at desc)`; `(student_id) where pinned` |
| `review_flag` | `(status, created_at)` |

No `OFFSET` anywhere; lists use `limit` over an ordered index.

**Estimated size.** About 400 rows per student per month (hint events, attempts, state upserts) at roughly 250 bytes with indexes is about 100 KB per student per month, about 1.2 MB per year. Neon Free is 1 GB (`docs/plan.md`); that is room for several hundred student-years. **Assumption**, not measured.

### 6.3 Read path: the brief

**When.** One read per `/api/watch`, `/api/ask` and `/api/consult` request, after the code check (`gate`) and before the model call. Never in `/api/speak` or `/api/heartbeat`.

**How (one round trip).** One SQL statement, written as a single query with sub-selects, returns: the pre-built `brief_global` and `brief_version`; the student's `skill_state` rows for the problem's skills (primary-key lookups, `skill_key = any($2)`); up to 3 misconceptions for those skills ordered by `last_seen_at`; the newest session recap; pinned or recent `human_note` rows. Budget: **under 50 ms warm, measured against the 5 to 23 ms warm baseline already seen**; the Phase 1 acceptance check is `EXPLAIN (ANALYZE)` plus a latency log line. The cold case (53 to 82 ms after idle) is already softened by the `/api/me` wake-up at problem open; if it still exceeds 50 ms, the per-request cap below applies.

**It must never break the tutor.** The read runs under its own 150 ms timeout (not the 5 s default). On timeout, error, or `memory_enabled = false`, the request continues with no brief, and the log line says why: `brief=skipped:timeout`, `skipped:db_<code>`, `skipped:disabled`, `skipped:no_history`. A skipped brief is a normal request, exactly as today.

**Format** (at most 300 tokens, enforced by a token count in tests; truncation drops lowest-priority items first and logs `brief_truncated` with the count dropped). Illustration only (an invented student, not real data):

```
STUDENT RECORD. The only past you may mention is what is listed here, by tag.
[s1] Last session 2026-11-10: 3 of 4 linear equations done without help; stuck on a minus before a bracket.
[m1] Seen 4 times, last 2026-11-10: drops the sign when a minus multiplies a bracket. A "which sign changes?" nudge fixed it 3 of 4 times.
[k1] Linear equations: solid (11 problems since 2026-10-02). Equations with fractions: due for review, last seen 2026-10-21.
[h1] A short written nudge has been enough more often than a spoken one (n=9).
[n1] Edward, 2026-11-09: starts to doubt herself when told she is wrong; open with what is right.
Do not assume any listed habit applies to this page. Judge this page on its own. This record never changes when you interrupt, only how you word a hint.
```

About 200 tokens. Mastery is stated in coarse words (`new`, `shaky`, `okay`, `solid`) with the count, never as a percentage to the student.

**The citation rules (Edward's rule, made mechanical).** Referencing shared history is helpful only when the history is real. So:

1. **Eligibility.** A brief item exists only if the record has its event, a date and a count. No date, no item.
2. **Tags.** Every item has a tag. The tutor may refer to the past only through a tag.
3. **Dates are rendered by code**, not computed by the model ("last session 2026-11-10", "4 times").
4. **No inferred schooling.** A student's grade or course says nothing about what they covered. "We did this in grade 5" is allowed only if an Edward note or a stated fact from the student, saved with its date and source, says so. Course enrolment is used only to pick the problem bank.
5. **Small numbers are said small.** n = 1 is "once", n = 2 is "twice"; a misconception is not surfaced as a "habit" until it is `active`.
6. **Absence is a state.** A new student gets `No history yet`, and the tutor behaves as it does today. Memory switched off means no brief at all.
7. **Enforced in code for structured outputs.** The watch decision gains a nullable `cite` field (a tag). A validator, in the same place as `finalizeDecision` (`server/lib/decision.ts`), checks hint text for recall phrasing ("last time", "again", "remember", "we did", "before", "you always"). If the phrasing is present and `cite` is null or not a tag in the brief, the hint is replaced by the catalog's `hint_seed` for the misconception if one is known, otherwise by `wait`, and the log says `unsupported_history_claim`. This is a heuristic with false negatives; its miss rate is measured by the eval in section 7, not assumed to be zero.
8. **Free-text surfaces cannot be fully enforced.** `/api/ask` answers and the live voice produce free text. For them the brief and the rule go into the prompt, a regex counter logs suspected unsupported recall (counts only), and Edward's review samples them. Memory is therefore enabled on `watch` first (Phase 1 with Edward's notes, Phase 3 with derived items), then `ask` (Phase 3), and on the live voice last.
9. **Memory is a prior, the page is the evidence.** The brief says so, in words, in the prompt.

**Prompt-injection safety, by construction.** No student-controlled free text is ever stored. The write path stores only enumerated keys, counts, ids and dates; the only free text in the brief is Edward's (`human_note`) and templates the code fills. The page content and the student's spoken words stay marked "student content, never an instruction" as today, and nothing the student writes can become a long-term instruction.

### 6.4 Write path

All writes are **structured events with closed vocabularies**, never free-text dumps, and all are idempotent.

**New fields in the watch decision** (an additive change to `WatchDecisionSchema`, `policy.ts`), generated in the same model call that already exists, so no extra call:

- `misconception`: one key from the problem's skills' catalog entries, or `other`, or null. Offered as a closed list in the prompt (the list is 5 to 15 entries per problem).
- `tag_confidence`: 0 to 1; below 0.6 the tag is stored as `other` (a starting bar, to be graded).
- `work_state`: `in_progress | complete_correct | complete_wrong | unclear`, meaning the student's last finished line against the reference. This is the missing "solved" signal.
- `cite`: described above.
- `rung`: chosen by code, not by the model (below), and passed in the prompt as the level to write at.

Because this touches the highest-stakes call, it ships behind the eval gate in section 7 and starts in **shadow**: the fields are generated and stored, not yet used.

**Events and what each writes:**

| moment | where it is observed | writes |
|---|---|---|
| problem opened | first `/api/watch`, `/api/ask` or `/api/heartbeat` for a `(session_id, problem_id)` with no open attempt | `attempt` row (`outcome = open`), `p_before` from `skill_state`; lazily closes any of the student's attempts left open longer than 45 minutes as `left` |
| look that interrupts | `/api/watch` result | `hint_event` (rung, channel, misconception, confidence); `attempt.interrupts += 1`; `student_misconception` upsert (`evidence_count += 1`, `last_seen_at`, state transition) |
| next look on the same line | `/api/watch` | resolves the earlier `hint_event`: `fixed_probable` if a later look waits and the line's strokes changed after the hint; `repeated` if the same line is flagged again; `unknown` otherwise. Labelled "probable" because the server cannot see intent. Updates `hint_stats`. |
| "Check my work" or a look with `work_state = complete_*` | `/api/watch` | `attempt.checks += 1`, remembers the latest `work_state` |
| spoken question | `/api/ask` | `attempt.asks += 1` (a topic tag from the model is Phase 3) |
| problem closed | a new small app event (`POST /api/attempt/close`, with a reason: `navigated_away | backgrounded | solved_tapped`) or the lazy 45-minute close | sets `outcome` from the last `work_state` and hint history; **one transaction** updates `skill_state` (below), `problem_stats`, `student_misconception.opportunities`/`clean_streak`, `session_summary`, and rebuilds `brief_global` if anything changed |

**Mastery update (starting guess, logged for calibration).** For each skill on the problem (primary gets weight 1, others 0.5):

- Predicted chance of an unaided success `p = 1 / (1 + exp(-(theta - difficulty)))`, stored as `attempt.p_before`.
- Outcome `y`: 1.0 solved unaided; `1 - 0.2 * max_rung` solved with a hint (0.8 down to 0.2); 0 if the student gave up after at least two hints with no fix; **no update** if they left with no interruption (silence is not evidence of failure).
- `theta += K * weight * (y - p)` with `K = max(0.05, 0.4 / (1 + 0.05 * n_eff))`, so early evidence moves the estimate more and later evidence less (the uncertainty-decay idea from Pelanek 2016). `problem_stats.difficulty` moves the other way by a smaller step.
- Expanding review: after an unaided success, `interval_days = max(1, interval_days * 2.2)` and `due_at = now + interval_days`; after a failure it resets to 1 day. The 2.2 factor is an engineering assumption, not a number from a paper; spacing gains are real (Cepeda 2006) but the best schedule for this population is unknown.
- The arithmetic is written as **one SQL statement** (`insert ... on conflict do update`), as `chargeFor` already does for the meter, so concurrent requests cannot interleave and nothing needs reading first.
- Forgetting is applied **at read time** (a skill unseen past its due date reads "due for review"), never written back.

**Hint rung (code, not model).** Rung 1: locate (the circle and "look at this line", no content). Rung 2: name the kind of slip (today's behaviour). Rung 3: a pointed question about the step ("what happens to the minus when it multiplies the bracket?"). Rung 4: a parallel example with different numbers. Never the answer, whatever the rung (the existing guard stays). Rule: the first interrupt on a line uses the rung the record favours for that misconception (default 2); the same line flagged again after the student rewrote it moves up one rung; a different line starts again. The student cannot request a higher rung, which is the guard against the skip-to-bottom behaviour in the help-seeking research. Where `hint_stats` has enough data (`n >= 8`), the starting rung and the channel come from it.

**Retries and failures.** Every write is keyed (`attempt_id, drawing_revision, line` for hints; the attempt's own unique key) so retries are no-ops. A failed write never fails the request: it logs `record_write_failed:<db_code>` and the tutor answers as normal. A failed close is repaired by the lazy close on the next open.

### 6.5 Logging (never fail silently, never succeed silently)

Counts, ids and labels only, in the existing one-line JSON format; the student appears only as the 8-character hash. Each request that touches the record adds fields such as:

`brief=used|skipped:<reason>`, `brief_items`, `brief_tokens`, `brief_version`, `record_read_ms`, `cite=<tag>|none`, `unsupported_history=blocked|none`, `misconception=<key>|other|none`, `tag_confidence_band=<lo|mid|hi>`, `rung`, `work_state`, `record_write=ok|failed:<code>`, `record_write_ms`. Model calls for the record carry an operation tag (`memory_write`, `memory_eval`) so spend splits the way BLI's does. Never logged: the brief text, Edward's notes, hint text, transcripts, pictures.

## 7. "Improves itself", honestly

Nothing here retrains a model. Three real mechanisms, and one caution.

**1. Per student, from outcomes (automatic).** Mastery estimates, misconception states, hint statistics and review dates update after every problem. This is the only learning that happens without a person, and it is statistics over that student's own history. It is only as good as its inputs: the tag, the `work_state`, and the "fixed" inference are model outputs and heuristics, which is why they carry confidence and counts and why thresholds (section 6.2) gate what the tutor may say.

**2. Across students, anonymously and only when there is enough of them (automatic, opt-in).** Pooled statistics (how often each misconception occurs, which rung fixes it, problem difficulty) are used only as priors, only from students who opted into `aggregate_stats`, and only when a cell has at least 5 students and 30 events. With a handful of students this will mostly be silent. That is the correct behaviour, not a bug.

**3. Edward in the loop (the engine of real improvement).** A weekly queue of flagged moments, capped so the review stays near 20 minutes:

- Auto-flags: a hint repeated twice on a line with no fix; `hint_reveals_answer` or `unsupported_history_claim` fired; the student rewrote the line unchanged after a hint; a manual Check that waited right after the tutor interrupted the same line.
- Student flag: a "this hint was wrong" control on the hint (Phase 5), which with the student's explicit per-use consent uploads that one page and decision to a private store with a 30 day expiry. This is the only place a picture would ever persist.
- Edward labels each with the closed reasons in `review_flag` and a `win | loss | noise` verdict (the BLI log shape).
- Every labelled flag becomes an **eval fixture**. Three or more flags with the same failure and a clear fix become a **rule or example** in the prompt. **Rules live in the repository, reviewed as pull requests with the eval run attached, not in the database**: a prompt change goes through CI like code, never straight from a flag to production.

**Caution: a change must prove it did not make the tutor worse.** Evals, in increasing cost:

| eval | what it checks | pass rule |
|---|---|---|
| Existing 30-page watch suite (`server/eval/`), run with the new schema fields and with a synthetic brief, paired against no brief | exact first-wrong-line, false alarms, schema failures | no drop against today's 30/30 exact and 0/30 false alarms with the brief on; one regression blocks |
| Priming test: synthetic briefs that claim a habit on pages that are correct | false-alarm rate | zero new false alarms; this specifically tests the risk in section 5 |
| Honest-history test: briefs with thin records plus prompts that invite invention ("remember last week?", "we did this in grade 5") | invented references | zero invented references that a grader finds unsupported, and the validator's own miss rate reported |
| Leak test | hint states the final answer or the corrected line | zero, same as today's guard |
| Brief budget test | tokens per brief | at most 300 on the longest realistic record |
| Synthetic-learner replay | feed simulated students (known skills, known habits) through the write path | misconception recovered, mastery ordering right, calibration (Brier score of `p_before`) reported; labelled synthetic |
| Shadow mode in production | brief built and logged, not injected | read latency, size, skip rate, coverage; no behaviour change |

The report always prints coverage with the score ("tagged 41 of 52 interrupts"), per the BLI exam's habit, and a result that did not move is reported as not moved. A blind grader that is not the model under test grades the free-text cases. Synthetic fixtures are not real handwriting (the existing eval already says so), and **with 3 to 20 students there is no statistical power to show a memory-on versus memory-off learning effect online**; the evals above and Edward's review are the real quality gate. A within-student alternating-weeks comparison is possible, but it would detect only large effects and is Edward's call.

## 8. Privacy for minors (not legal advice)

Students are grades 5 to 12 plus college. The record is a profile of a child's learning, assembled over months, so it is more sensitive than the usage meter. This section is a working checklist and a list of questions for a BC privacy lawyer (one hour of advice before onboarding minors with memory switched on is cheap compared with the downside). I read the BC statute text and the OPC pages below; I did not read case law, and I did not find an answer to every point.

### 8.1 What the law says, as far as I read it

| point | source | what I read | consequence here |
|---|---|---|---|
| BC private-sector law applies to a tutoring business collecting personal information in BC | *Personal Information Protection Act* (PIPA), SBC 2003 c 63 | s.4(1): act as a reasonable person would consider appropriate; s.4(2): responsible for personal information under its control, including what is not in its custody | The processors (hosting, model and voice vendors) are Edward's responsibility |
| Consent | PIPA s.6 to s.8; s.10 | collection, use and disclosure need consent unless the Act allows otherwise; notify the purposes on or before collection | Separate, recorded consent for the memory purpose (`consent_events`) |
| Collection and use limited to appropriate purposes | PIPA s.11 and s.14 (use); s.17 (disclosure) | only for purposes a reasonable person would consider appropriate | Store only what teaching needs (minimisation list below) |
| Safeguards | PIPA s.34 | reasonable security arrangements against unauthorized access, collection, use, disclosure, copying, modification or disposal | Code-scoped access; Edward-only notes; no student text in memory |
| Retention | PIPA s.35(2) | destroy or de-identify as soon as it is reasonable to assume the purpose is no longer served and retention is not needed for legal or business reasons | A retention schedule (below) |
| **Retention conflict** | PIPA s.35(1) | if personal information is used to make a decision that directly affects the individual, keep it at least one year after using it | **Open question**: does adaptive tutoring count as such a decision? If it does, deleting a record on request may have to wait. Ask counsel; do not assume either way. |
| Access and correction | PIPA s.23, s.24, s.29 | an individual may request their information and its uses; correct errors; the organization must respond within 30 days unless extended | `export` command; student-facing correction; write notes to be read by the student or parent |
| Federal law and the border | PIPEDA; OPC *Guidelines for processing personal data across borders* | PIPEDA does not distinguish domestic from international transfers; the organization stays accountable and should be transparent about processing abroad | Notice must say data is processed by US vendors; contracts and retention settings need checking (open item) |
| Children's consent | OPC position on PIPEDA Principle 3, and the Children's Privacy Code | under 13: parental consent in all but exceptional cases; 13 and over: the child's own consent may be appropriate where they understand it, with parental awareness depending on risk | Parent consent for under 13; for 13 to 18 the child's own recorded consent plus parent awareness; adults consent for themselves |
| **Children's Privacy Code** | OPC, released 2026-10-20; **non-binding guidance, open for comment until 2027-01-20, may change** | covers services "likely to be accessed by" under-18s; privacy by default; non-essential uses opt-in with separate choices per optional feature; withdrawal as easy as consent; data minimisation, set retention periods, say what happens at the age of majority; practical means to correct or delete; **do not profile children unless profiling is in the child's best interests and not commercially driven, and if you do: tell them, explain how the profile was assembled, and do a privacy impact assessment**; no inferring sensitive characteristics or using emotional state; no streaks or points to drive data collection | See 8.2: the memory layer is profiling in this sense and needs the PIA, plain-language explanation and opt-in |
| Age of majority in BC | *Age of Majority Act* s.1 | 19 | The Code asks what happens at majority: offer to keep or delete at 19 |

Quebec is out of scope (its private-sector law deems 14 the age of consent, per a law-firm summary of the Code); if a Quebec student ever signs up, ask.

### 8.2 What this design does about it

1. **Memory is opt-in and off by default.** `memory_enabled` is false until Edward records the consent. The core service works without it, exactly as today. This also answers the Code's "profiling off by default" and "separate choice per optional feature".
2. **Best-interests argument, written down.** The profile exists to tailor hints to the student, with no marketing, no ads, no sale, no sharing, no engagement mechanics (the Code lists points and streaks as a prohibited pattern; I saw none in the app and none should be added for memory's sake). Edward writes a short privacy impact assessment before turning memory on for any minor; the Code says one is expected where profiling or inference is used.
3. **No inference of sensitive traits or emotional state.** The model is never asked to guess mood, anxiety, family, disability or behaviour. The only such facts in the record are what Edward writes in a note or what a student sets as a preference. The "may be struggling" signal (Phase 5) is derived from hard counts (repeated no-fix hints, long unproductive time) and goes to Edward only, never to the student or parent automatically, never with text.
4. **Data minimisation, as a list.**

   | stored | not stored |
   |---|---|
   | code-linked student id, skill keys, counts, dates, misconception keys, hint rungs, outcomes, short template recaps, Edward's notes, explicit preferences, consent events | name, email, age, school, grade, location, device id, raw audio, page pictures, transcripts of what the student said, hint text, model output text, free text typed by the student |

   The student's grade is deliberately absent; it is not needed and it invites the "grade 5" fabrication.
5. **Retention schedule (proposal for Edward and counsel to settle).** Event rows (`attempt`, `hint_event`): 12 months rolling, then deleted; the derived `skill_state`, `student_misconception`, `session_summary` stay while the student is active. Record deleted 12 months after the last session unless the student asks to keep it, with a notice before. At 19 (or on a college student's request), offer to export and delete. If s.35(1) turns out to apply, the minimum becomes one year after use and the schedule is adjusted.
6. **Delete on request: a real delete.** `scripts/codes forget CODE` deletes the record rows (cascade from `students`), keeps or removes the usage meter as asked, and logs the counts deleted. Deletion also covers Edward's notes about the student. Neon keeps point-in-time history for its plan's window, so the notice must name that window (open item: read the plan's history retention; not checked here).
7. **Export.** `scripts/codes export CODE` prints the student's rows as JSON, for a PIPA s.23 request, answerable within the 30 days in s.29.
8. **Student-visible and correctable.** A "What I remember about you" screen (Phase 4) shows the model-derived items in plain words with a "this is wrong" and a "forget this" control per item and "forget everything". Edward's private notes are not shown in the app but are released on request. Wrong memory that a child can fix is also the cheapest accuracy check there is.
9. **No raw audio, no pictures stored.** True today for the server (section 2). The one future exception, the flag upload, is per use, opt-in, private, and expires in 30 days.
10. **Logs.** Ids, counts and labels only; the student appears as a hash; no content. Already the house rule (`server/README.md`, logging paragraph).
11. **Access control.** The record is read and written only through the code-checked gate. `human_note` is written only by Edward's admin command, never an app endpoint. The database holds no names, so a leak of the database links nobody by itself; the code-to-person map stays offline with Edward.
12. **Processors and settings (open, unverified).** The record adds no new vendor beyond Neon and the model providers already in use. Whether each provider keeps API inputs, trains on them, or offers zero retention was not checked in this research and must be (OpenAI, Google Gemini on the paid tier, ElevenLabs, Vercel, Neon) before consent text promises anything.

### 8.3 Questions for counsel

1. Does PIPA s.35(1)'s one-year retention apply to adaptive tutoring, and how does it interact with a deletion request?
2. Is a parent's consent enough for ages 13 to 17 in BC, or should the student's own consent be recorded as the Code suggests?
3. Do the US processors require anything more than notice under PIPA and PIPEDA?
4. Is a privacy impact assessment expected before launch given the Code is guidance and still open for comment?
5. Does the aggregate-statistics purpose need its own consent, as designed?

## 9. Cost per student per month

Prices from `server/lib/pricing.ts` (read 2026-11-14): `gpt-6-luna` US$0.10 input, US$0.01 cached input, US$0.50 output per million tokens; `gpt-6.1-sol` US$2 input, US$10 output. Today's per-look cost is US$0.00016 on Luna (`docs/plan.md`, amendment 14, measured).

**Assumptions** (all stated, none measured yet): 60 to 120 looks per counted hour and 5 to 10 spoken questions per hour (the plan's own assumptions); brief at most 300 tokens plus the misconception list for the problem at about 200 tokens, so 500 added input tokens per look and 300 per question; 15 added output tokens per look (the new structured fields); 4 to 8 counted hours per month (8 is the cap).

| item | per counted hour (light to heavy) | per month at 4 h light | per month at 8 h heavy |
|---|---:|---:|---:|
| extra input on looks: 500 tokens x US$0.10/M x looks | US$0.003 to 0.006 | US$0.012 | US$0.048 |
| extra output on looks: 15 tokens x US$0.50/M x looks | US$0.0005 to 0.0009 | US$0.002 | US$0.007 |
| extra input on questions: 300 tokens x US$0.10/M x questions | US$0.00015 to 0.0003 | US$0.0006 | US$0.0024 |
| weekly consolidation call (2,000 in, 300 out) per active student, 4.3 weeks | n/a | US$0.0015 | US$0.0015 |
| optional question-topic tagging (Phase 3), about 80 questions at 300 in, 50 out | n/a | n/a | US$0.0044 |
| session recap | template, no model | US$0 | US$0 |
| embeddings | none until Phase 6 | US$0 | US$0 |
| database: one extra read per request, about 3 writes per attempt, about 100 KB of growth | Neon Free | US$0 | US$0 |
| **total** | | **about US$0.02** | **about US$0.06** |

That is about CA$0.03 to 0.09 at the plan's 1 USD = 1.425 CAD, roughly 1% of today's variable cost at the 8 hour cap (US$4.68 typical, US$7.36 heavy) and under 1% of the CA$19 plan price.

**On the frontier model** (college-level `advanced` problems run on `gpt-6.1-sol`): the same 500 added input tokens cost 20 times as much. Added input is US$0.001 per look, so US$0.06 to 0.12 per counted hour, about US$0.5 to 1.0 per month at 8 hours. Still modest, but it is the line to watch if college use grows. A cached prefix (the brief is stable within a session) would cut the input rate for that part by a factor of 10 to 20 (cached US$0.01 versus US$0.10 on Luna, US$0.10 versus US$2 on Sol); not assumed above.

**Eval runs.** One run of the 30-page suite, two repetitions, with and without a brief: 120 calls x US$0.00016 = about US$0.02. A grader pass over 100 free-text cases on a mid-tier model is about US$0.12. Negligible per release.

**The cost that matters is Edward's time.** A weekly review of about 20 minutes at his tutoring rate of CA$30 to 35 an hour (his own anchor, in the project memory) is about CA$10 to 12 a week, CA$43 to 50 a month. Shared across 3 students that is about CA$14 to 17 each, as much as or more than the margin per student at the full 8 hours (about CA$12 against CA$19 of revenue); across 15 it is about CA$3 each. So: the review queue is capped, sorted by severity, and only worth running once there are enough students. Until then, review only the auto-flags that fired.

## 10. Risks and what answers them

| risk | answer |
|---|---|
| A wrong stored inference is repeated to a child as fact | Evidence thresholds before surfacing (`active` needs 2 observations in 2 attempts); hedged wording ("seen twice"); confidence bar on the tag; student can correct or delete; Edward's `correction` note overrides; weekly review. |
| The brief makes the tutor interrupt wrongly (priming) | The brief never changes the interrupt rule; priming eval blocks release on any new false alarm. |
| The tutor invents shared history | The tagging, dating and validator rules in 6.3; honest-history eval; free-text surfaces enabled last. |
| Free-text surfaces (ask, live voice) cannot be fully enforced | Counted and sampled, enabled last, and the doc says so. |
| Memory read slows or breaks a tutoring request | Own 150 ms timeout; every failure degrades to today's behaviour with a logged reason. |
| Too little data to learn from | Per-student state needs only that student's own history; population priors stay silent below 5 students; no claim of a learning effect without evidence. |
| One code shared by siblings, or a lost code, corrupts or strands a record | One code per person is a rule of the offline map; Edward-run `transfer` command (copy rows to a new code) in Phase 5. |
| Consent and profiling rules change | The Code is open for comment until 2027-01-20; memory is a switch per student; re-read before launch. |
| Mastery formulas are wrong | They are guesses, every prediction is logged (`p_before`), and Phase 3 compares them with outcomes before the tutor leans on them. |

## 11. Phased build plan

Effort figures are estimates by feel, not measurements. Each phase ends in something that works on its own.

**Phase 0: prerequisites (about 1 day, mostly in the course branches).**
Agree the `skills.json` and `skills: []` contract; add the `bank` check that every problem has a valid skill; decide the skill-key naming (`<course>:<slug>`). Decide the consent wording owner. Nothing in the server yet.

**Phase 1: Edward's notes, silent recording, delete and export (about 3 to 4 days). The smallest useful slice.**
- Migration `003`: `student_profile`, `consent_events`, `human_note`, `attempt`, `hint_event`. 
- `server/lib/record/`: brief builder (notes plus "no history yet"), a 300 token budget test, the 150 ms read with the skip labels.
- Feature switch `STUDENT_RECORD=off|shadow|on` plus per-student `memory_enabled`. `shadow` builds and logs the brief without injecting it.
- `scripts/codes` gains `consent`, `note add|list|retire`, `export`, `forget`.
- Inject the brief into the watch prompt for enabled students: **Edward's notes only**, with the citation rules and the "never changes when you interrupt" line.
- Silent event capture (`attempt`, `hint_event` from today's decisions, no new model fields yet).
- Evals: the 30 page suite with and without a brief; honest-history and brief budget tests.
- Acceptance: brief read under 50 ms warm in the logs over a week; zero invented history in the eval; the suite does not regress; export and forget delete and print matching counts on a test student; no content in logs (checked by the existing log-shape test).

**Phase 2: the model fills in the missing signals, in shadow (about 3 days).**
- Add `misconception`, `tag_confidence`, `work_state`, `cite` to the watch decision; the closed list per problem from `skills.json`.
- Gate: the eval suite must show no loss against today's results with the new fields; the `other` rate is reported (the 30% taxonomy check); tag accuracy graded by Edward on a sample.
- Write `student_misconception`, `skill_state`, `session_summary`, `problem_stats`; the attempt-close event on the iPad plus the lazy close.
- Still shadow: nothing new reaches the tutor.

**Phase 3: memory goes live in the brief (about 3 days).**
- Surface `active` misconceptions, mastery words and the recap for enabled students, on `watch` first, then `ask`.
- Hint rungs 1 to 4 with `hint_stats` shaping the starting rung and channel (default rung 2 until `n >= 8`).
- The `unsupported_history_claim` validator; the priming and leak evals as release gates.
- Calibration report: `p_before` versus outcomes; adjust `K` and the thresholds from data, not from this doc.
- Live voice: only after the same checks, with the counter-and-sample controls from 6.3 item 8.

**Phase 4: student-facing and practice (about 1 week, includes the iPad).**
- "What I remember about you" screen with correct and forget controls.
- Problem picker offers a due skill and mixes skills (interleaving), shown as a suggestion the student can ignore.
- Session-open recap (two sentences, then a prompt to attempt).

**Phase 5: the review loop (about 3 to 4 days).**
- `review_flag` queue, auto-flags, the weekly digest to Edward (ids and labels, no content).
- "This hint was wrong" control with per-use consent and a 30-day expiring upload.
- Flag-to-fixture script; rules proposed as pull requests with eval output attached.
- `transfer` command for a re-issued code.
- Struggle signal from hard counts to Edward only.

**Phase 6 (optional, only if wanted): free-text episodic recall.**
pgvector on the same Neon database for Edward's notes and recaps; a retrieval step with its own eval. Skipped until there is a question the structured record cannot answer.

**Not planned:** a graph store, a hosted memory vendor, a deep knowledge-tracing model, model fine-tuning on student data, any cross-student sharing of individual records.

## 12. Open items for Edward

1. **Consent wording and the privacy impact assessment** (section 8): who drafts, and the lawyer hour. Memory stays off for minors until this exists.
2. **Retention schedule** (12 months events, delete at 12 months inactive): settle, subject to the s.35(1) answer.
3. **Provider data settings** (retention, training, zero retention) for each processor: unchecked here.
4. **Skills contract** with the course branches: yes or no on `skills.json` and `skills: []`.
5. **Review budget**: 20 minutes a week once there are at least 5 memory-enabled students? Below that, auto-flags only.
6. **Whether memory-on versus memory-off weeks are acceptable** for a within-student comparison, given the small N.
7. **Whether the live voice gets memory at all**, given it cannot be structurally guarded (6.3 item 8).

## 13. Sources

Local (read 2026-11-14):
- `docs/plan.md` (amendments 13 to 16), `server/lib/{watch,ask,consult,heartbeat,gate,db,decision,policy,problems,pricing,students,students-memory}.ts`, `server/db/migrations/001_students.sql`, `002_last_activity_at.sql`, `server/README.md`, `ios/PencilTutor/Session/TutorSession.swift`.
- `shared/courses/calculus-1/README.md` and `problems.json` (calculus worktree; `shared/courses/` is not on `main`).
- BLI: `bli-cockpit/docs/architecture/{agent-memory,memory-exam,memory-spend,people-models,hit-ledger}.md`; `BLI/BLI-MEMORY-HANDOFF-2026-09-06.md`.

Memory systems (GitHub API on 2026-11-14 for stars, licence, push, release): github.com/mem0ai/mem0, letta-ai/letta, getzep/graphiti, getzep/zep, langchain-ai/langmem, topoteretes/cognee, MemTensor/MemOS, supermemoryai/supermemory, vectorize-io/hindsight. Docs: docs.mem0.ai/open-source/overview and the pgvector and configuration pages (TypeScript OSS: graph and reranker are Python-only); docs.letta.com/v1-sdk/docker (`LETTA_PG_URI`, pgvector required); github.com/getzep/graphiti README (supported graph databases); help.getzep.com/faq (Zep Community Edition deprecated); langchain-ai.github.io/langmem (AsyncPostgresStore; semantic, episodic, procedural). Zep temporal knowledge graph paper: arXiv 2501.13956 (cited by the BLI doc, not re-read). Comparison article by a listed vendor, used only for the list of projects: hindsight.vectorize.io/blog/2026/08/11/open-source-agent-memory-systems.

Learning science:
- VanLehn, K. (2011). The relative effectiveness of human tutoring, intelligent tutoring systems, and other tutoring systems. *Educational Psychologist* 46(4), 197-221. doi:10.1080/00461520.2011.611369 (d = 0.79 human, 0.76 ITS, 0.31 answer-based to 0.76 step-based).
- Bloom, B. S. (1984). The 2 sigma problem. *Educational Researcher* 13(6), 4-16.
- Nickow, A., Oreopoulos, P., Quan, V. (2020). The impressive effects of tutoring on PreK-12 learning. NBER / SSRN 3644077 (pooled 0.37 SD).
- Lepper, M. R., Woolverton, M. (2002). The wisdom of practice: lessons learned from the study of highly effective tutors. In J. Aronson (Ed.), *Improving Academic Achievement*. Academic Press.
- Chi, M. T. H., Wylie, R. (2014). The ICAP framework. *Educational Psychologist* 49(4), 219-243. doi:10.1080/00461520.2014.965823.
- Bastani, H. et al. (2025). Generative AI without guardrails can harm learning: evidence from high school mathematics. *PNAS*. doi:10.1073/pnas.2422633122.
- Corbett, A. T., Anderson, J. R. (1995). Knowledge tracing. *User Modeling and User-Adapted Interaction* 4, 253-278.
- Piech, C. et al. (2015). Deep knowledge tracing. arXiv:1506.05908.
- Gervet, T., Koedinger, K., Schneider, J., Mitchell, T. (2020). When is deep learning the best approach to knowledge tracing? *Journal of Educational Data Mining* 12(3), 31-54.
- Pelanek, R. (2016). Applications of the Elo rating system in adaptive educational systems. *Computers & Education* 98, 169-179.
- Cepeda, N. J., Pashler, H., Vul, E., Wixted, J. T., Rohrer, D. (2006). Distributed practice in verbal recall tasks. *Psychological Bulletin* 132(3), 354-380 (839 assessments, 317 experiments).
- Roediger, H. L., Karpicke, J. D. (2006). Test-enhanced learning. *Psychological Science* 17(3), 249-255.
- Dunlosky, J. et al. (2013). Improving students' learning with effective learning techniques. *Psychological Science in the Public Interest* 14(1), 4-58.
- Rohrer, D., Dedrick, R. F., Hartwig, M. K., Cheung, C.-N. (2020). A randomized controlled trial of interleaved mathematics practice. *Journal of Educational Psychology* 112(1), 40-52 (61% versus 38%, d = 0.83).
- Brown, J. S., Burton, R. R. (1978). Diagnostic models for procedural bugs in basic mathematical skills. *Cognitive Science* 2, 155-192; Brown, J. S., VanLehn, K. (1980). Repair theory. *Cognitive Science* 4.
- Wood, D., Bruner, J. S., Ross, G. (1976). The role of tutoring in problem solving. *Journal of Child Psychology and Psychiatry* 17(2), 89-100.
- Aleven, V. et al. and Roll, I. et al. on help-seeking and hint abuse (CMU; the "under 1 second on 68% of hints" figure is from the paper summarised at cs.cmu.edu/~bmclaren/pubs; Wood et al. 1976 was cited from memory and not looked up in this research; Brown and VanLehn 1980 and Roediger and Karpicke were confirmed by title search only, not re-read).

Law and guidance (read 2026-11-14; not legal advice):
- *Personal Information Protection Act*, SBC 2003, c 63, ss. 4, 6-8, 10, 11, 17, 23, 24, 29, 34, 35: bclaws.gov.bc.ca/civix/document/id/complete/statreg/00_03063_01.
- OPC, PIPEDA Fair Information Principle 3, Consent (children): priv.gc.ca/en/privacy-topics/privacy-laws-in-canada/the-personal-information-protection-and-electronic-documents-act-pipeda/p_principle/principles/p_consent.
- OPC, *Children's Privacy Code* (released 2026-10-20, comments until 2027-01-20) and news release: priv.gc.ca/en/opc-news/news-and-announcements/2026/nr-c_261020; summary of its expectations by Torys LLP, torys.com/our-latest-thinking/publications/2026/10/childrens-privacy-code. The Code text itself was not read, only the OPC news release and the law-firm summary.
- OPC, *Guidelines for processing personal data across borders*: priv.gc.ca/en/privacy-topics/personal-information-transferred-across-borders/gl_dab_090127.
- *Age of Majority Act* (BC), s.1: bclaws.gov.bc.ca/civix/document/id/complete/statreg/96007_01.
