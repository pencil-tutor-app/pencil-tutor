import { z } from "zod";
import { defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { findProblem } from "./problems.js";

const HeartbeatSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
});

// POST /api/heartbeat: "a problem is open and the student was active in the last 2 minutes". The app sends one about every
// 60 seconds while that is true, and never otherwise. Watch, ask and consult requests already count as activity on their own;
// the heartbeat covers the time between them (a student thinking, or writing a long line, with nothing to send).
export async function handleHeartbeat(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("heartbeat", request.method);

  const opened = await gate(ctx, request, deps, []);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = HeartbeatSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  if (!findProblem(parsed.data.problem_id)) return ctx.fail(422, "unknown_problem", "problem_id is not in the bank", "unknown_problem");

  await meterActivity(ctx, opened, "heartbeat");
  return ctx.respond(200, { ok: true }, "ok", "counted");
}
