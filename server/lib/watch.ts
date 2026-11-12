import { z } from "zod";
import { finalizeDecision, scriptedWatch, type WatchResult } from "./decision.js";
import { defaultDeps, gate, issueReason, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { checkImage } from "./image.js";
import { runWatchModel } from "./models.js";
import { buildWatchPrompt, HistoryEntrySchema, LineSchema, MAX_HISTORY, MAX_LINES } from "./policy.js";
import { findProblem } from "./problems.js";

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

  const opened = gate(ctx, request, deps, ["watch"]);
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
    const cfg = opened.configs.watch!;
    modelName = cfg.model;
    const model = deps.models.language(cfg, opened.keys.watch!);
    const out = await runWatchModel({
      model,
      promptText: buildWatchPrompt({ problem, lines: req.lines, history, clientTime: req.client_time }),
      image: image.image,
    });
    if (out.kind === "failed") return ctx.fail(out.status, out.error, out.label, `${out.error}:${out.label}`);
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
