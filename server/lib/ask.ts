import { z } from "zod";
import { SCRIPTED_ANSWER, SCRIPTED_TRANSCRIPT } from "./decision.js";
import { configForLevel, defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runAskModel, runTranscription } from "./models.js";
import { buildAskPrompt } from "./policy.js";
import { levelOf, problemFields, resolveProblem } from "./problems.js";
import { afterQuestion } from "./record/runtime.js";
import { usageFields } from "./usage.js";

export const MAX_AUDIO_BYTES = 2_500_000;
const EMPTY_TRANSCRIPT_ANSWER = "I didn't catch that. Please hold the button and ask again.";
const NO_ANSWER_TEXT = "I couldn't come up with an answer. Please ask again.";

const AskRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  // The typed statement of an own problem ("own:<course>"); required then, ignored for a bank id (problems.ts resolveProblem).
  problem_text: z.string().optional(),
  drawing_revision: z.number().int().nonnegative().optional(),
  audio_base64: z.string().min(1),
  image_png_base64: z.string().min(1),
  image_width: z.number().optional(),
  image_height: z.number().optional(),
});

export async function handleAsk(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("ask", request.method);

  const opened = await gate(ctx, request, deps, ["ask", "stt"]);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = AskRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;

  const image = checkImage(req.image_png_base64);
  if (!image.ok) {
    ctx.note({ image_bytes: image.bytes });
    return ctx.fail(422, "invalid_image", image.reason, `invalid_image:${image.reason}`);
  }
  ctx.note({ image_bytes: image.image.bytes });

  const audio = Buffer.from(req.audio_base64, "base64");
  ctx.note({ audio_bytes: audio.length });
  if (audio.length === 0) return ctx.fail(422, "invalid_audio", "audio_empty", "invalid_audio:audio_empty");
  if (audio.length > MAX_AUDIO_BYTES) {
    return ctx.fail(422, "invalid_audio", "audio_over_2_5_MB", "invalid_audio:audio_over_2_5_MB");
  }

  const resolved = resolveProblem(req.problem_id, req.problem_text);
  if (!resolved.ok) return ctx.fail(resolved.status, resolved.error, resolved.reason, resolved.error);
  const problem = resolved.problem;
  ctx.note(problemFields(problem));

  // A valid question is student activity.
  await meterActivity(ctx, opened, "question");
  await afterQuestion(ctx, deps, opened, { sessionId: req.session_id, problemId: problem.id });

  const echo = req.drawing_revision === undefined ? {} : { drawing_revision: req.drawing_revision };
  const done = (transcript: string, answer: string, model: string, label: string) => {
    ctx.note({ transcript_chars: transcript.length, answer_chars: answer.length });
    return ctx.respond(
      200,
      { transcript, answer_text: answer, ...echo, model, latency_ms: Date.now() - ctx.startedAt },
      "ok",
      label,
    );
  };

  if (opened.scripted) return done(SCRIPTED_TRANSCRIPT, SCRIPTED_ANSWER, "scripted", "scripted_answer");

  const picked = configForLevel(ctx, opened, deps.env, "ask", levelOf(problem));
  if (!picked.ok) return picked.response;
  const askCfg = picked.cfg;
  const sttCfg = opened.configs.stt!;
  if (askCfg.effort) ctx.note({ effort: askCfg.effort });
  ctx.note({ stt_model: sttCfg.model });

  const heard = await runTranscription({ model: deps.models.transcription(sttCfg, opened.keys.stt!), audio });
  if (heard.kind === "failed") return ctx.fail(heard.status, heard.error, `stt_${heard.label}`, `${heard.error}:stt_${heard.label}`);
  if (!heard.text) return done("", EMPTY_TRANSCRIPT_ANSWER, askCfg.model, "empty_transcript");

  const answered = await runAskModel({
    model: deps.models.language(askCfg, picked.key),
    cfg: askCfg,
    promptText: buildAskPrompt({ problem, transcript: heard.text }),
    image: image.image,
  });
  if (answered.kind === "failed") return ctx.fail(answered.status, answered.error, answered.label, `${answered.error}:${answered.label}`);
  ctx.note(usageFields(answered.usage));
  if (!answered.text) return done(heard.text, NO_ANSWER_TEXT, askCfg.model, "empty_answer");
  return done(heard.text, answered.text, askCfg.model, "answered");
}
