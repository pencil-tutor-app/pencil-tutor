import { z } from "zod";
import { defaultDeps, gate, issueReason, meterActivity, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { findProblem } from "./problems.js";

// How old a reported activity may be. An app that was in the background or offline can report a stale moment; anything older
// than an hour is treated as "no activity reported" rather than trusted.
export const MAX_REPORTED_AGE_SECONDS = 3600;

const HeartbeatSchema = z.object({
  session_id: z.string().max(100).optional(),
  problem_id: z.string().max(40),
  // How long ago the student's last real activity (ink, a question, a look, live voice talk) was, in seconds, measured on the
  // device's own clock so a wrong device clock cannot move it. Left out when nothing new happened since the last heartbeat.
  seconds_since_activity: z.number().optional(),
});

// The moment of the last real activity as the server sees it: now minus the age the app reported. Null (with a label saying
// why) when the app reported none, or a number that makes no sense.
export function reportedActivity(now: Date, secondsAgo: number | undefined): { at: Date | null; label: string } {
  if (secondsAgo === undefined) return { at: null, label: "none_reported" };
  if (!Number.isFinite(secondsAgo) || secondsAgo < 0 || secondsAgo > MAX_REPORTED_AGE_SECONDS) return { at: null, label: "out_of_range" };
  return { at: new Date(now.getTime() - Math.floor(secondsAgo) * 1000), label: "reported" };
}

// POST /api/heartbeat: "here is when the student last really did something". The app sends one about every 30 seconds while a
// problem is open and there is activity it has not reported yet, and never otherwise. A heartbeat is NOT activity by itself:
// it only carries the time of activity that really happened (ink and live voice talk produce no other request). A heartbeat
// with no activity, or with a repeat of one already counted, charges 0 s, so a student who leaves the iPad on the table
// accrues nothing. Watch, ask and consult requests are activity on their own and do not need it.
export async function handleHeartbeat(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("heartbeat", request.method);

  const opened = await gate(ctx, request, deps, []);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = HeartbeatSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  if (!findProblem(parsed.data.problem_id)) return ctx.fail(422, "unknown_problem", "problem_id is not in the bank", "unknown_problem");

  const activity = reportedActivity(opened.now, parsed.data.seconds_since_activity);
  ctx.note({ heartbeat_activity: activity.label });
  if (activity.at) ctx.note({ seconds_since_activity: Math.floor(parsed.data.seconds_since_activity ?? 0) });
  await meterActivity(ctx, opened, "heartbeat", activity.at);
  return ctx.respond(200, { ok: true }, "ok", activity.at ? "activity_reported" : `no_activity_${activity.label}`);
}
