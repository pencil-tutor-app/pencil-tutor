import { z } from "zod";
import { SCRIPTED_TRANSCRIPT } from "./decision.js";
import { apiKeyFor, ConfigError, missingKeyReason, roleConfig, teachLevel, type Level, type RoleConfig } from "./config.js";
import { defaultDeps, gate, issueReason, meterActivity, type Deps, type GateOpen } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { logLine, type LogFields } from "./log.js";
import { runTranscription } from "./models.js";
import { MAX_AUDIO_BYTES } from "./ask.js";
import { MAX_TURNS, TurnSchema } from "./policy.js";
import { cleanProblemText, findCourse, OWN_PREFIX, problemFields, type Course, type Problem } from "./problems.js";
import { sealKeyFor, sealReference } from "./seal.js";
import { guardSpokenAnswer, stripSentenceEnd } from "./spoken.js";
import { resolveRequestProblem } from "./teach-ref.js";
import {
  buildComparerPrompt,
  buildExplainPrompt,
  buildFollowupPrompt,
  buildPracticePrompt,
  buildSolverPrompt,
  COMPARER_SYSTEM,
  ComparerOutputSchema,
  explainSystem,
  ExampleSchema,
  ExplainOutputSchema,
  followupSystem,
  FollowupOutputSchema,
  LIMITS,
  MESSAGE_NOT_MATH,
  MESSAGE_BEYOND_COURSE,
  MESSAGE_OTHER_COURSE,
  PracticeOutputSchema,
  practiceSystem,
  SOLVER_SYSTEM,
  SolverOutputSchema,
  type Example,
} from "./teach-policy.js";
import { runStructured, type StructuredResult } from "./teach-models.js";
import type { ModelFailure } from "./models.js";
import { usageFields, type UsageReport } from "./usage.js";

// POST /api/teach: learn a new concept, then try one yourself. Three actions, one gate, one log line each:
//   explain   the concept in, a short lesson (steps, one worked example, a spoken summary) out
//   followup  a question about the lesson (typed or spoken) with the last 8 turns, an answer out
//   practice  one problem on the concept, checked by a blind solver and a comparer, sealed so the watch path can use its solution
// Design: docs/teach-mode-plan.md (Revision 2 wins).

const EMPTY_TRANSCRIPT_ANSWER = "I didn't catch that. Please hold the button and ask again.";

export const SCRIPTED_LESSON = {
  title: "Solving a two-step equation",
  steps: ["Undo the adding or subtracting first.", "Then undo the multiplying by dividing both sides by the same number."],
  example: { prompt_plain: "3x + 2 = 14", steps: ["3x = 12", "x = 4"], final_answer: "x = 4" },
  spoken: "A two-step equation needs two undoing moves, one at a time.",
};
// What explain returns when there is no lesson (not maths, or another course): the lesson fields are present and null.
const NO_LESSON = { title: null, steps: null, example: null, spoken: null };

export const SCRIPTED_PRACTICE = { prompt_plain: "2x + 3 = 11", steps: ["2x = 8", "x = 4"], final_answer: "x = 4" };
export const SCRIPTED_FOLLOWUP_ANSWER = "This is a scripted answer. Undo the adding first, then the multiplying.";

const Common = { session_id: z.string().max(100).optional(), course: z.string().max(60) };
const Concept = z.string().max(LIMITS.concept * 2).refine((c) => c.trim().length > 0 && c.trim().length <= LIMITS.concept, `concept must be 1 to ${LIMITS.concept} characters`);

const TeachRequestSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("explain"), ...Common, concept: Concept }),
  z.object({
    action: z.literal("followup"),
    ...Common,
    concept: Concept,
    lesson_text: z.string().max(LIMITS.lessonText),
    recent: z.array(TurnSchema).max(MAX_TURNS).default([]),
    question: z.string().max(800).optional(),
    audio_base64: z.string().min(1).optional(),
    problem_text: z.string().optional(),
    problem_ref: z.string().max(6000).optional(),
    attempted: z.boolean().optional(),
  }),
  // The lesson as text (what the student read) and, when it has passed its way to the screen, its worked example. An absent example is
  // simply not checked: example_checked comes back false and nothing is withheld.
  z.object({ action: z.literal("practice"), ...Common, concept: Concept, lesson_text: z.string().max(LIMITS.lessonText), example: ExampleSchema.optional() }),
]);
type TeachRequest = z.infer<typeof TeachRequestSchema>;

// ---------------------------------------------------------------- shared helpers

type Picked = { ok: true; cfg: RoleConfig; key: string } | { ok: false; status: 503; error: string; reason: string };

// The model for a level, without touching the request's log fields (the check always runs on the advanced model while the
// lesson runs on the teach level, and both must be reported).
function pick(env: Deps["env"], level: Level): Picked {
  let cfg: RoleConfig;
  try {
    cfg = roleConfig("ask", env, level);
  } catch (err) {
    return { ok: false, status: 503, error: "bad_config", reason: err instanceof ConfigError ? err.message : "bad configuration" };
  }
  const key = apiKeyFor(cfg.provider, env);
  return key ? { ok: true, cfg, key } : { ok: false, status: 503, error: "missing_key", reason: missingKeyReason(cfg.provider) };
}

const prefixed = (prefix: string, usage: UsageReport | undefined): LogFields =>
  Object.fromEntries(Object.entries(usageFields(usage)).map(([k, v]) => [`${prefix}${k}`, v]));

const totalCost = (usages: (UsageReport | undefined)[]): number | null => {
  const costs = usages.flatMap((u) => (u?.est_cost_usd == null ? [] : [u.est_cost_usd]));
  return costs.length ? Math.round(costs.reduce((a, b) => a + b, 0) * 1e7) / 1e7 : null;
};

// A named event next to the request's own log line: what the plan asks to be able to count (practice_not_checked, example_withheld ...).
const logEvent = (ctx: RequestCtx, event: string, fields: LogFields = {}) =>
  logLine("info", { request_id: ctx.id, endpoint: ctx.endpoint, event, ...fields });

const failModel = (ctx: RequestCtx, f: ModelFailure) => ctx.fail(f.status, f.error, f.label, `${f.error}:${f.label}`);

// A structured call that did not produce an object: the length limit was broken (teach_too_long) or the answer was unusable.
function unusable(ctx: RequestCtx, r: Exclude<StructuredResult<unknown>, { kind: "object" }>): Response {
  if (r.kind === "too_long") {
    logEvent(ctx, "teach_too_long");
    return ctx.fail(502, "teach_too_long", "model_answer_over_limit", "teach_too_long");
  }
  return ctx.fail(502, "teach_unusable", "model_answer_not_usable", "teach_unusable");
}

// ---------------------------------------------------------------- the two-call check

export type Verdict = "agree" | "disagree" | "not_single" | "wrong_step" | "malformed" | "same_as_example" | "no_example" | "error";

type Checked = { verdict: Verdict; solve?: UsageReport; compare?: UsageReport; failure?: ModelFailure };

// Call 1 (blind): the solver sees only the statement and returns its own final answer.
// Call 2: the comparer sees the statement, the proposed steps and answer, and the solver's answer, and returns
// { equivalent, single_answer, first_wrong_step }. The reference is accepted only when both agree, the answer is single and no
// step is wrong. Never retried, never regenerated: a failed check is reported as it is.
export async function checkStatement(deps: Deps, checker: { cfg: RoleConfig; key: string }, item: { statement: string; steps: string[]; finalAnswer: string }): Promise<Checked> {
  const model = deps.models.language(checker.cfg, checker.key);
  const solved = await runStructured({ model, cfg: checker.cfg, system: SOLVER_SYSTEM, prompt: buildSolverPrompt(item.statement), schema: SolverOutputSchema });
  if (solved.kind === "failed") return { verdict: "error", failure: solved };
  if (solved.kind !== "object") return { verdict: "malformed", solve: solved.usage };
  const compared = await runStructured({
    model,
    cfg: checker.cfg,
    system: COMPARER_SYSTEM,
    prompt: buildComparerPrompt({ statement: item.statement, steps: item.steps, finalAnswer: item.finalAnswer, solverAnswer: solved.value.final_answer }),
    schema: ComparerOutputSchema,
  });
  if (compared.kind === "failed") return { verdict: "error", solve: solved.usage, failure: compared };
  if (compared.kind !== "object") return { verdict: "malformed", solve: solved.usage, compare: compared.usage };
  const { equivalent, single_answer, first_wrong_step } = compared.value;
  const verdict: Verdict = !equivalent ? "disagree" : !single_answer ? "not_single" : first_wrong_step !== null ? "wrong_step" : "agree";
  return { verdict, solve: solved.usage, compare: compared.usage };
}

// ---------------------------------------------------------------- the handler

export async function handleTeach(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("teach", request.method);

  const opened = await gate(ctx, request, deps, ["ask", "stt"]);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = TeachRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;

  const course = findCourse(req.course);
  if (!course) return ctx.fail(422, "unknown_course", "course is not in the bank", "unknown_course");
  // Sizes and labels only. The concept, the lesson, the problem and the answers are never logged.
  ctx.note({ action: req.action, course: course.slug, concept_chars: req.concept.trim().length });

  if (req.action === "explain") return explain(ctx, deps, opened, course, req);
  if (req.action === "followup") return followup(ctx, deps, opened, course, req);
  return practice(ctx, deps, opened, course, req);
}

type Of<A extends TeachRequest["action"]> = Extract<TeachRequest, { action: A }>;

// ---------------------------------------------------------------- explain

async function explain(ctx: RequestCtx, deps: Deps, opened: GateOpen, course: Course, req: Of<"explain">): Promise<Response> {
  const respond = (extra: Record<string, unknown>, model: string, label: string) =>
    ctx.respond(200, { ...extra, model, latency_ms: Date.now() - ctx.startedAt }, "ok", label);

  await meterActivity(ctx, opened, "question");
  if (opened.scripted) {
    ctx.note({ is_math: true, fits_course: true, steps: SCRIPTED_LESSON.steps.length, example_lines: SCRIPTED_LESSON.example.steps.length });
    return respond({ is_math: true, fits_course: true, message: null, ...SCRIPTED_LESSON }, "scripted", "scripted_lesson");
  }

  const picked = pick(deps.env, teachLevel(deps.env));
  if (!picked.ok) return ctx.fail(picked.status, picked.error, picked.reason, picked.error);
  ctx.note({ level: picked.cfg.level, provider: picked.cfg.provider, model: picked.cfg.model, ...(picked.cfg.effort ? { effort: picked.cfg.effort } : {}) });

  const out = await runStructured({
    model: deps.models.language(picked.cfg, picked.key),
    cfg: picked.cfg,
    system: explainSystem(course),
    prompt: buildExplainPrompt(req.concept.trim()),
    schema: ExplainOutputSchema,
  });
  if (out.kind === "failed") return failModel(ctx, out);
  ctx.note({ ...prefixed("gen_", out.usage), est_cost_usd: out.usage.est_cost_usd });
  if (out.kind !== "object") return unusable(ctx, out);

  const lesson = out.value;
  ctx.note({ is_math: lesson.is_math, fits_course: lesson.fits_course });
  if (!lesson.is_math) return respond({ is_math: false, fits_course: false, message: MESSAGE_NOT_MATH, ...NO_LESSON }, picked.cfg.model, "not_math");
  const complete = lesson.title.trim() && lesson.steps.length > 0 && lesson.example.prompt_plain.trim() && lesson.example.steps.length > 0 && lesson.example.final_answer.trim() && lesson.spoken.trim();
  if (!lesson.fits_course) {
    logEvent(ctx, "concept_outside_course", { course: course.slug, taught: Boolean(complete) });
    // Maths past the course is still taught when the model wrote a full lesson; only an empty one falls back to the refusal.
    if (complete) {
      ctx.note({ steps: lesson.steps.length, example_lines: lesson.example.steps.length });
      return respond(
        { is_math: true, fits_course: false, message: MESSAGE_BEYOND_COURSE, title: lesson.title, steps: lesson.steps, example: lesson.example, spoken: lesson.spoken },
        picked.cfg.model,
        "lesson_beyond_course",
      );
    }
    return respond({ is_math: true, fits_course: false, message: MESSAGE_OTHER_COURSE, ...NO_LESSON }, picked.cfg.model, "concept_outside_course");
  }
  if (!complete) return ctx.fail(502, "teach_unusable", "lesson_incomplete", "teach_unusable");

  ctx.note({ steps: lesson.steps.length, example_lines: lesson.example.steps.length });
  return respond(
    { is_math: true, fits_course: true, message: null, title: lesson.title, steps: lesson.steps, example: lesson.example, spoken: lesson.spoken },
    picked.cfg.model,
    "lesson",
  );
}

// ---------------------------------------------------------------- followup

async function followup(ctx: RequestCtx, deps: Deps, opened: GateOpen, course: Course, req: Of<"followup">): Promise<Response> {
  const hasText = Boolean(req.question?.trim());
  if (hasText === Boolean(req.audio_base64)) return ctx.fail(422, "invalid_request", "send exactly one of question and audio_base64", "invalid_request");
  ctx.note({ recent_turns: req.recent.length, input: hasText ? "typed" : "voice", lesson_chars: req.lesson_text.length });

  // A practice problem in play: the sealed reference gives the answer guard its final answer. Invalid or expired is 422
  // practice_expired, never a quiet fall back (the guard would be lost).
  let practiceProblem: Problem | undefined;
  if (req.problem_ref) {
    const resolved = resolveRequestProblem(ctx, deps.env, deps.now?.() ?? new Date(), { problem_id: `${OWN_PREFIX}${course.slug}`, problem_text: req.problem_text, problem_ref: req.problem_ref });
    if (!resolved.ok) return ctx.fail(resolved.status, resolved.error, resolved.reason, resolved.error);
    practiceProblem = resolved.problem;
    ctx.note(problemFields(practiceProblem));
  }

  let audio: Buffer | undefined;
  if (req.audio_base64) {
    audio = Buffer.from(req.audio_base64, "base64");
    ctx.note({ audio_bytes: audio.length });
    if (audio.length === 0) return ctx.fail(422, "invalid_audio", "audio_empty", "invalid_audio:audio_empty");
    if (audio.length > MAX_AUDIO_BYTES) return ctx.fail(422, "invalid_audio", "audio_over_2_5_MB", "invalid_audio:audio_over_2_5_MB");
  }

  await meterActivity(ctx, opened, "question");
  const done = (transcript: string | null, answer: string, model: string, label: string) => {
    ctx.note({ ...(transcript === null ? {} : { transcript_chars: transcript.length }), answer_chars: answer.length });
    return ctx.respond(200, { transcript, answer_text: answer, model, latency_ms: Date.now() - ctx.startedAt }, "ok", label);
  };
  if (opened.scripted) return done(audio ? SCRIPTED_TRANSCRIPT : null, SCRIPTED_FOLLOWUP_ANSWER, "scripted", "scripted_answer");

  const picked = pick(deps.env, teachLevel(deps.env));
  if (!picked.ok) return ctx.fail(picked.status, picked.error, picked.reason, picked.error);
  ctx.note({ level: picked.cfg.level, provider: picked.cfg.provider, model: picked.cfg.model, ...(picked.cfg.effort ? { effort: picked.cfg.effort } : {}) });

  let question = (req.question ?? "").trim();
  let transcript: string | null = null;
  if (audio) {
    const sttCfg = opened.configs.stt!;
    ctx.note({ stt_model: sttCfg.model });
    const heard = await runTranscription({ model: deps.models.transcription(sttCfg, opened.keys.stt!), audio });
    if (heard.kind === "failed") return ctx.fail(heard.status, heard.error, `stt_${heard.label}`, `${heard.error}:stt_${heard.label}`);
    if (!heard.text) return done("", EMPTY_TRANSCRIPT_ANSWER, picked.cfg.model, "empty_transcript");
    question = heard.text;
    transcript = heard.text;
  } else {
    ctx.note({ question_chars: question.length });
  }

  const out = await runStructured({
    model: deps.models.language(picked.cfg, picked.key),
    cfg: picked.cfg,
    system: followupSystem(course),
    prompt: buildFollowupPrompt({ concept: req.concept.trim(), lessonText: req.lesson_text, recent: req.recent, question, practice: practiceProblem, attempted: req.attempted }),
    schema: FollowupOutputSchema,
  });
  if (out.kind === "failed") return failModel(ctx, out);
  ctx.note({ ...prefixed("gen_", out.usage), est_cost_usd: out.usage.est_cost_usd });
  if (out.kind !== "object") return unusable(ctx, out);

  const answer = out.value.answer_text.trim();
  if (!answer) return done(transcript, "I couldn't come up with an answer. Please ask again.", picked.cfg.model, "empty_answer");
  if (practiceProblem) {
    const guarded = guardSpokenAnswer(practiceProblem, answer);
    if (guarded.withheld) {
      ctx.note({ answer_withheld: true });
      logEvent(ctx, "answer_withheld");
      return done(transcript, guarded.text, picked.cfg.model, "answer_withheld");
    }
  }
  return done(transcript, answer, picked.cfg.model, "answered");
}

// ---------------------------------------------------------------- practice

async function practice(ctx: RequestCtx, deps: Deps, opened: GateOpen, course: Course, req: Of<"practice">): Promise<Response> {
  const key = sealKeyFor(deps.env);
  if (!key) return ctx.fail(503, "teach_unavailable", "TEACH_SEAL_KEY is not set", "teach_unavailable");

  // A prefetch is not student work: it still settles the allowance and its notices but charges no seconds.
  await meterActivity(ctx, opened, "question", null);
  const now = deps.now?.() ?? new Date();
  const problemId = `${OWN_PREFIX}${course.slug}`;
  const respond = (extra: Record<string, unknown>, model: string, label: string) =>
    ctx.respond(200, { ...extra, model, latency_ms: Date.now() - ctx.startedAt }, "ok", label);

  if (opened.scripted) {
    const ref = sealReference(key, { course: course.slug, worked_solution: SCRIPTED_PRACTICE.steps, final_answer: SCRIPTED_PRACTICE.final_answer }, SCRIPTED_PRACTICE.prompt_plain, now);
    ctx.note({ checker: "agree", example_check: "agree", example_checked: true, reference: "sealed" });
    return respond({ example_checked: true, problem: { id: problemId, prompt_plain: SCRIPTED_PRACTICE.prompt_plain }, problem_ref: ref, reason: null }, "scripted", "scripted_practice");
  }

  const generator = pick(deps.env, teachLevel(deps.env));
  if (!generator.ok) return ctx.fail(generator.status, generator.error, generator.reason, generator.error);
  const checker = pick(deps.env, "advanced");
  if (!checker.ok) return ctx.fail(checker.status, checker.error, checker.reason, checker.error);
  ctx.note({
    level: generator.cfg.level,
    provider: generator.cfg.provider,
    model: generator.cfg.model,
    check_model: checker.cfg.model,
    ...(generator.cfg.effort ? { effort: generator.cfg.effort } : {}),
    ...(checker.cfg.effort ? { check_effort: checker.cfg.effort } : {}),
  });

  const example: Example | undefined = req.example;
  // The example is checked while the practice problem is written: the two share no input.
  const exampleCheck: Promise<Checked> = example
    ? checkStatement(deps, checker, { statement: example.prompt_plain, steps: example.steps, finalAnswer: example.final_answer })
    : Promise.resolve<Checked>({ verdict: "no_example" });
  const generated = await runStructured({
    model: deps.models.language(generator.cfg, generator.key),
    cfg: generator.cfg,
    system: practiceSystem(course),
    prompt: buildPracticePrompt({ concept: req.concept.trim(), lessonText: req.lesson_text, example }),
    schema: PracticeOutputSchema,
  });
  if (generated.kind === "failed") {
    await exampleCheck;
    return failModel(ctx, generated);
  }
  ctx.note(prefixed("gen_", generated.usage));
  if (generated.kind !== "object") {
    await exampleCheck;
    return unusable(ctx, generated);
  }
  // The answer is kept without a closing full stop, so the checks and the guards read the same string the page shows.
  const problem = { ...generated.value, final_answer: stripSentenceEnd(generated.value.final_answer) };
  const usable = problem.prompt_plain.trim() && problem.final_answer.trim() && problem.steps.length >= 2 && problem.steps.every((s) => s.trim());
  const sameAsExample = example !== undefined && cleanProblemText(problem.prompt_plain) === cleanProblemText(example.prompt_plain);

  const practiceCheck: Promise<Checked> = !usable
    ? Promise.resolve<Checked>({ verdict: "malformed" })
    : sameAsExample
      ? Promise.resolve<Checked>({ verdict: "same_as_example" })
      : checkStatement(deps, checker, { statement: problem.prompt_plain, steps: problem.steps, finalAnswer: problem.final_answer });
  const [exampleChecked, practiceChecked] = await Promise.all([exampleCheck, practiceCheck]);

  ctx.note({
    ...prefixed("example_solve_", exampleChecked.solve),
    ...prefixed("example_compare_", exampleChecked.compare),
    ...prefixed("check_solve_", practiceChecked.solve),
    ...prefixed("check_compare_", practiceChecked.compare),
    example_check: exampleChecked.verdict,
    checker: practiceChecked.verdict,
    est_cost_usd: totalCost([generated.usage, exampleChecked.solve, exampleChecked.compare, practiceChecked.solve, practiceChecked.compare]),
  });

  // A rejected example is withheld, not shown with a warning: the lesson keeps its steps and the example slot stays empty.
  const exampleOk = exampleChecked.verdict === "agree";
  if (!exampleOk && example) {
    ctx.note({ example_withheld: true });
    logEvent(ctx, "example_withheld", { example_check: exampleChecked.verdict });
  }
  // A provider failure while checking the practice problem is a failed request (the app offers Try again); it is not a rejection.
  if (practiceChecked.failure) return failModel(ctx, practiceChecked.failure);

  if (practiceChecked.verdict !== "agree") {
    logEvent(ctx, "practice_not_checked", { checker: practiceChecked.verdict });
    return respond({ example_checked: exampleOk, problem: null, problem_ref: null, reason: "not_checked" }, generator.cfg.model, "practice_not_checked");
  }

  const ref = sealReference(key, { course: course.slug, worked_solution: problem.steps, final_answer: problem.final_answer }, problem.prompt_plain, now);
  ctx.note({ reference: "sealed" });
  return respond(
    { example_checked: exampleOk, problem: { id: problemId, prompt_plain: cleanProblemText(problem.prompt_plain) }, problem_ref: ref, reason: null },
    generator.cfg.model,
    "practice_checked",
  );
}
