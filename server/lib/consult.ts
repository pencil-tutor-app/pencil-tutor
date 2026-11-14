import { z } from "zod";
import { configForLevel, defaultDeps, gate, issueReason, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runAskModel } from "./models.js";
import { buildConsultPrompt, CONSULT_POLICY } from "./policy.js";
import { findProblem, levelOf } from "./problems.js";
import { usageFields } from "./usage.js";

export const SCRIPTED_CONSULT_ANSWER = "This is a scripted page report. Line one is written and the latest line looks unfinished. Ask what they did to both sides.";
const NO_ANSWER_TEXT = "I couldn't read the page just now. Ask the student to try again in a moment.";

const TurnSchema = z.object({
  role: z.enum(["student", "tutor"]),
  text: z.string().max(400),
});

const ConsultRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  drawing_revision: z.number().int().nonnegative().optional(),
  image_png_base64: z.string().min(1),
  // What the student just said, from the Live session's own transcript (no audio crosses this endpoint).
  question: z.string().max(800).refine((q) => q.trim().length > 0, "question must not be blank"),
  recent: z.array(TurnSchema).max(8).default([]),
});

// POST /api/consult: the page reader GPT-Live delegates to. GPT-Live cannot take images, so the iPad sends the page
// picture here over HTTPS when a delegation fires. Same gate, image rules, ask model and failure labels as /api/ask.
export async function handleConsult(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("consult", request.method);

  const opened = gate(ctx, request, deps, ["ask"]);
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

  const problem = findProblem(req.problem_id);
  if (!problem) return ctx.fail(422, "unknown_problem", "problem_id is not in the bank", "unknown_problem");

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
    promptText: buildConsultPrompt({ problem, question: req.question, recent: req.recent }),
    image: image.image,
    system: CONSULT_POLICY,
  });
  if (answered.kind === "failed") return ctx.fail(answered.status, answered.error, answered.label, `${answered.error}:${answered.label}`);
  ctx.note(usageFields(answered.usage));
  if (!answered.text) return done(NO_ANSWER_TEXT, cfg.model, "empty_answer");
  return done(answered.text, cfg.model, "answered");
}
