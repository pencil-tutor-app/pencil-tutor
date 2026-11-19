import { z } from "zod";
import { SCRIPTED_ANSWER, SCRIPTED_TRANSCRIPT } from "./decision.js";
import {
  addCounted,
  addReserve,
  countText,
  FREE_MAX_AUDIO_BYTES,
  maxOutputTokensOf,
  notCalled,
  sttActualMicros,
  sttReserve,
  textReserve,
  type Counted,
} from "./free-config.js";
import { countModelResult, paidCall, refuse } from "./free-spend.js";
import { configForLevel, defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runAskModel, runTranscription } from "./models.js";
import { buildAskPrompt } from "./policy.js";
import { findProblem, levelOf, tierOf } from "./problems.js";
import { afterQuestion } from "./record/runtime.js";
import { usageFields } from "./usage.js";

export const MAX_AUDIO_BYTES = 2_500_000;
const EMPTY_TRANSCRIPT_ANSWER = "I didn't catch that. Please hold the button and ask again.";
const NO_ANSWER_TEXT = "I couldn't come up with an answer. Please ask again.";

const AskRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
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
  // A free code's question may be at most 300 KB (the app's 30-second limit is 26 to 114 KB), which bounds what speech-to-text can cost.
  if (opened.student.origin === "free" && audio.length > FREE_MAX_AUDIO_BYTES) {
    return ctx.fail(422, "invalid_audio", "audio_over_300_KB_for_free_code", "invalid_audio:audio_over_300_KB_for_free_code");
  }

  const problem = findProblem(req.problem_id);
  if (!problem) return ctx.fail(422, "unknown_problem", "problem_id is not in the bank", "unknown_problem");
  ctx.note({ course: problem.course ?? "none", tier: tierOf(problem) });

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

  // Speech to text, then the answer, as one metered unit for a free code (lib/free-spend.ts): the worst case of both is reserved first
  // and the pair is settled afterwards. The answer step is skipped (and its share given back) when there is no transcript.
  const free = opened.student.origin === "free";
  const cap = maxOutputTokensOf(deps.env);
  const parts = () => {
    const stt = sttReserve(sttCfg.model, audio.length);
    const text = textReserve(askCfg.model, opened.now, cap);
    return stt && text ? { stt, text } : undefined;
  };
  type Heard = Awaited<ReturnType<typeof runTranscription>>;
  type Answered = Awaited<ReturnType<typeof runAskModel>>;
  const paid = await paidCall<{ heard: Heard; answered?: Answered }>(ctx, deps.env, opened, {
    kind: "ask",
    reserve: () => {
      const p = parts();
      return p ? addReserve(p.stt, p.text) : undefined;
    },
    run: async () => {
      const heard = await runTranscription({ model: deps.models.transcription(sttCfg, opened.keys.stt!), audio });
      if (heard.kind === "failed" || !heard.text) return { heard };
      const answered = await runAskModel({
        model: deps.models.language(askCfg, picked.key),
        cfg: askCfg,
        promptText: buildAskPrompt({ problem, transcript: heard.text }),
        image: image.image,
        maxOutputTokens: free ? cap : undefined,
      });
      return { heard, answered };
    },
    count: ({ heard, answered }) => {
      const p = parts()!;
      if (heard.kind === "failed") return countText(undefined, `stt_${heard.label}`, p.stt);
      const seconds = heard.durationSeconds;
      const speech: Counted =
        seconds === null
          ? { micros: p.stt.perAttempt, basis: "reserve_kept_no_usage", detail: "stt_no_duration" }
          : { micros: sttActualMicros(sttCfg.model, seconds) ?? p.stt.perAttempt, basis: "estimated" };
      return addCounted(speech, answered ? countModelResult(answered, p.text) : notCalled);
    },
  });
  if (!paid.ok) return refuse(ctx, paid.refusal);
  const { heard, answered } = paid.value;
  if (heard.kind === "failed") return ctx.fail(heard.status, heard.error, `stt_${heard.label}`, `${heard.error}:stt_${heard.label}`);
  if (!heard.text || !answered) return done("", EMPTY_TRANSCRIPT_ANSWER, askCfg.model, "empty_transcript");
  if (answered.kind === "failed") return ctx.fail(answered.status, answered.error, answered.label, `${answered.error}:${answered.label}`);
  ctx.note(usageFields(answered.usage));
  if (!answered.text) return done(heard.text, NO_ANSWER_TEXT, askCfg.model, "empty_answer");
  return done(heard.text, answered.text, askCfg.model, "answered");
}
