import { defaultDeps, gate, type Deps } from "./gate.js";
import { RequestCtx } from "./http.js";

// GET /api/me: who this code is (as a plan, never a name) and how many hours are left this month. It is free: it does not
// count as activity. The app calls it when the student types a code (that is how a code is checked), when the app opens and
// when a problem opens (which also wakes the database before the first real request).
export async function handleMe(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("me", request.method);

  const opened = await gate(ctx, request, deps, [], { method: "GET", allowOverCap: true });
  if (!opened.ok) return opened.response;

  const { student } = opened;
  ctx.note({ plan_live: student.planLive });
  return ctx.respond(
    200,
    { plan: { live: student.planLive, cap_minutes: Math.round(student.capSeconds / 60) } },
    "ok",
    "me",
  );
}
