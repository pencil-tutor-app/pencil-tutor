import { z } from "zod";
import { configForLevel, defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runAskModel } from "./models.js";
import { buildConsultPrompt, CONSULT_POLICY, MAX_TURNS, TurnSchema } from "./policy.js";
import { levelOf, problemFields } from "./problems.js";
import { afterQuestion } from "./record/runtime.js";
import { guardSpokenAnswer } from "./spoken.js";
import { resolveRequestProblem } from "./teach-ref.js";
import { usageFields } from "./usage.js";

export const SCRIPTED_CONSULT_ANSWER = "This is a scripted page report. Line one is written and the latest line looks unfinished. Ask what they did to both sides.";
const NO_ANSWER_TEXT = "I couldn't read the page just now. Ask the student to try again in a moment.";

const ConsultRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  // The typed statement of an own problem ("own:<course>"); required then, ignored for a bank id (problems.ts resolveProblem).
  problem_text: z.string().optional(),
  // The sealed reference of a teach practice problem (lib/seal.ts); with it the problem has its checked solution and answer.
  problem_ref: z.string().max(6000).optional(),
  // Whether the student has finished a line of their own work on a practice problem. Missing counts as false.
  attempted: z.boolean().optional(),
  drawing_revision: z.number().int().nonnegative().optional(),
  image_png_base64: z.string().min(1),
  // What the student just said, from the Live session's own transcript (no audio crosses this endpoint).
  question: z.string().max(800).refine((q) => q.trim().length > 0, "question must not be blank"),
  recent: z.array(TurnSchema).max(MAX_TURNS).default([]),
});

// POST /api/consult: the page reader GPT-Live delegates to. GPT-Live cannot take images, so the iPad sends the page
// picture here over HTTPS when a delegation fires. Same gate, image rules, ask model and failure labels as /api/ask.
export async function handleConsult(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("consult", request.method);

  const opened = await gate(ctx, request, deps, ["ask"]);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = ConsultRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;

  const image = checkImage(req.image_png_base64);
  if (!image.ok) {
    ctx.note({ image_bytes: image.bytes });
    return ctx.fail(422, "invalid_image", image.reason, `invalid_image:${image.reason}`);
  }
  // Sizes and counts only. The student's words and the answer are never logged.
  ctx.note({ image_bytes: image.image.bytes, question_chars: req.question.length, recent_turns: req.recent.length });

  const resolved = resolveRequestProblem(ctx, deps.env, deps.now?.() ?? new Date(), req);
  if (!resolved.ok) return ctx.fail(resolved.status, resolved.error, resolved.reason, resolved.error);
  const problem = resolved.problem;
  ctx.note(problemFields(problem));

  // A valid question to the page reader is student activity.
  await meterActivity(ctx, opened, "question");
  await afterQuestion(ctx, deps, opened, { sessionId: req.session_id, problemId: problem.id });

  const echo = req.drawing_revision === undefined ? {} : { drawing_revision: req.drawing_revision };
  const done = (answer: string, model: string, label: string) => {
    ctx.note({ answer_chars: answer.length });
    return ctx.respond(200, { answer_text: answer, ...echo, model, latency_ms: Date.now() - ctx.startedAt }, "ok", label);
  };

  if (opened.scripted) return done(SCRIPTED_CONSULT_ANSWER, "scripted", "scripted_answer");

  const picked = configForLevel(ctx, opened, deps.env, "ask", levelOf(problem));
  if (!picked.ok) return picked.response;
  const cfg = picked.cfg;
  if (cfg.effort) ctx.note({ effort: cfg.effort });
  const answered = await runAskModel({
    model: deps.models.language(cfg, picked.key),
    cfg,
    promptText: buildConsultPrompt({ problem, question: req.question, recent: req.recent, attempted: req.attempted }),
    image: image.image,
    system: CONSULT_POLICY,
  });
  if (answered.kind === "failed") return ctx.fail(answered.status, answered.error, answered.label, `${answered.error}:${answered.label}`);
  ctx.note(usageFields(answered.usage));
  if (!answered.text) return done(NO_ANSWER_TEXT, cfg.model, "empty_answer");
  const guarded = guardSpokenAnswer(problem, answered.text);
  if (guarded.withheld) {
    ctx.note({ answer_withheld: true });
    return done(guarded.text, cfg.model, "answer_withheld");
  }
  return done(answered.text, cfg.model, "answered");
}
