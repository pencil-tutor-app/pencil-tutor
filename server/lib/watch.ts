import { z } from "zod";
import { finalizeDecision, scriptedWatch, type WatchResult } from "./decision.js";
import { maxOutputTokensOf, textReserve } from "./free-config.js";
import { countModelResult, paidCall, refuse } from "./free-spend.js";
import { configForLevel, defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runWatchModel } from "./models.js";
import { buildWatchPrompt, HistoryEntrySchema, LineSchema, MAX_HISTORY, MAX_LINES } from "./policy.js";
import { findProblem, levelOf, tierOf } from "./problems.js";
import { afterLook } from "./record/runtime.js";
import { usageFields } from "./usage.js";

const WatchRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  drawing_revision: z.number().int().nonnegative(),
  image_png_base64: z.string().min(1),
  image_width: z.number().optional(),
  image_height: z.number().optional(),
  lines: z.array(LineSchema).max(MAX_LINES).default([]),
  history: z.array(z.unknown()).max(1000).default([]),
  client_time: z.union([z.string(), z.number()]).optional(),
});

export async function handleWatch(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("watch", request.method);

  const opened = await gate(ctx, request, deps, ["watch"]);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = WatchRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;
  ctx.note({ line_count: req.lines.length, drawing_revision: req.drawing_revision });

  const image = checkImage(req.image_png_base64);
  if (!image.ok) {
    ctx.note({ image_bytes: image.bytes });
    return ctx.fail(422, "invalid_image", image.reason, `invalid_image:${image.reason}`);
  }
  ctx.note({ image_bytes: image.image.bytes });

  const problem = findProblem(req.problem_id);
  if (!problem) return ctx.fail(422, "unknown_problem", "problem_id is not in the bank", "unknown_problem");
  ctx.note({ course: problem.course ?? "none", tier: tierOf(problem) });

  // A valid look is student activity: ink was drawn, and the tutor is looking at it. This keeps the meter running.
  await meterActivity(ctx, opened, "look");

  // History: last 10 only; entries that do not parse are dropped and counted.
  const recent = req.history.slice(-MAX_HISTORY);
  const history = recent.flatMap((h) => {
    const r = HistoryEntrySchema.safeParse(h);
    return r.success ? [r.data] : [];
  });
  ctx.note({ history_in: req.history.length, history_used: history.length });

  let result: WatchResult;
  let modelName = "scripted";
  if (opened.scripted) {
    result = scriptedWatch(req.problem_id, req.lines, history);
  } else {
    const picked = configForLevel(ctx, opened, deps.env, "watch", levelOf(problem));
    if (!picked.ok) return picked.response;
    const cfg = picked.cfg;
    modelName = cfg.model;
    if (cfg.effort) ctx.note({ effort: cfg.effort });
    const model = deps.models.language(cfg, picked.key);
    // For a free code the call is bounded (an output-token cap) and metered (reserve before, settle after): lib/free-spend.ts.
    const cap = maxOutputTokensOf(deps.env);
    const free = opened.student.origin === "free";
    const paid = await paidCall(ctx, deps.env, opened, {
      kind: "watch",
      reserve: () => textReserve(cfg.model, opened.now, cap),
      run: () =>
        runWatchModel({
          model,
          cfg,
          promptText: buildWatchPrompt({ problem, lines: req.lines, history, clientTime: req.client_time }),
          image: image.image,
          maxOutputTokens: free ? cap : undefined,
        }),
      count: countModelResult,
    });
    if (!paid.ok) return refuse(ctx, paid.refusal);
    const out = paid.value;
    if (out.kind === "failed") return ctx.fail(out.status, out.error, out.label, `${out.error}:${out.label}`);
    // Tokens, estimated cost and provider time: counts and labels only, never the page or the model's words.
    ctx.note(usageFields(out.usage));
    result =
      out.kind === "malformed"
        ? {
            action: "wait",
            line: null,
            reason: "The model answer was not usable, so waiting.",
            hint_spoken: null,
            hint_written: null,
            label: out.label,
          }
        : finalizeDecision(out.raw, req.lines, problem);
  }

  // Opt-in student memory (lib/record): records the look for a student who agreed and may reword the SPOKEN hint. The decision
  // above, and the written hint, are never touched by it. With no consent, or the switch off, this returns the result unchanged.
  result = await afterLook(ctx, deps, opened, { sessionId: req.session_id, problem, revision: req.drawing_revision, result });

  ctx.note({ action: result.action, line: result.line, reason_label: result.label });
  return ctx.respond(
    200,
    {
      action: result.action,
      line: result.line,
      reason: result.reason,
      hint_spoken: result.hint_spoken,
      hint_written: result.hint_written,
      drawing_revision: req.drawing_revision,
      model: modelName,
      latency_ms: Date.now() - ctx.startedAt,
    },
    "ok",
    result.label,
  );
}
