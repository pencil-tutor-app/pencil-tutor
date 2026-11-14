import { z } from "zod";
import { defaultDeps, gate, issueReason, timedDb, type Deps } from "../gate.js";
import { DatabaseError } from "../db.js";
import { RequestCtx, readJson } from "../http.js";
import { NOTICE, NOTICE_VERSION, noticeHash, POLICY_PATH } from "./notice.js";
import { PRIVACY_POLICY_MD } from "./policy-text.js";
import { logConsentChange, managementStore, recordSwitchedOn } from "./runtime.js";
import type { Deleted, RecordStore, Status } from "./store.js";

// /api/memory: the app's side of the opt-in. GET says what the server offers and what it holds (counts, never contents);
// POST consents, withdraws or erases. Code-authenticated, allowed when the month's hours are used up, never counted as activity.
// Managing an existing record never depends on the STUDENT_RECORD switch (a rollback must not trap anyone's data); a NEW grant does.

const ActionSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("consent"),
    given_by: z.enum(["parent_guardian", "adult_student"]),
    notice_version: z.string().max(40),
    attested: z.boolean(),
  }),
  z.object({ action: z.literal("withdraw"), erase: z.boolean().default(false) }),
  z.object({ action: z.literal("erase") }),
]);

function consentBody(status: Status) {
  const c = status.consent;
  if (!c) return null;
  return {
    granted: c.granted,
    // Memory runs only on a grant of the CURRENT notice version.
    current: c.granted && c.noticeVersion === NOTICE_VERSION,
    given_by: c.givenBy,
    recorded_via: c.recordedVia,
    notice_version: c.noticeVersion,
    at: c.at,
  };
}

const deletedBody = (d: Deleted) => ({ withdrawn: d.withdrawn > 0, deleted: { hints: d.hints, attempts: d.attempts, notes: d.notes } });

const unavailable = (ctx: RequestCtx, label: string) => ctx.fail(503, "database_unavailable", label, `database_unavailable:${label}`);
const labelOf = (err: unknown) => (err instanceof DatabaseError ? err.label : "db_error");

export async function handleMemoryStatus(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("memory", request.method);
  const opened = await gate(ctx, request, deps, [], { method: "GET", allowOverCap: true });
  if (!opened.ok) return opened.response;
  const store = managementStore(deps);
  if (!store) return unavailable(ctx, "DATABASE_URL is not set");

  let status: Status;
  try {
    status = await timedDb(ctx, () => store.status(opened.student.id));
  } catch (err) {
    return unavailable(ctx, labelOf(err));
  }
  const on = recordSwitchedOn(deps.env);
  const hasRecord = status.consent !== null || status.notes > 0 || status.recent.length > 0;
  ctx.note({ memory_feature: on ? "on" : "off", memory_consent: status.consent ? (status.consent.granted ? "granted" : "withdrawn") : "none", memory_notes: status.notes });
  if (!on && !hasRecord) return ctx.respond(200, { feature: "off" }, "ok", "memory_off");
  const origin = new URL(request.url).origin;
  return ctx.respond(
    200,
    {
      feature: on ? "on" : "off",
      notice: { version: NOTICE_VERSION, ...NOTICE, policy_url: `${origin}${POLICY_PATH}` },
      consent: consentBody(status),
      record: {
        notes: status.notes,
        recent: status.recent.map((r) => ({ problem_id: r.problemId, looks: r.looks, asks: r.asks, interrupts: r.interrupts, last_at: r.lastAt })),
      },
    },
    "ok",
    "memory_status",
  );
}

export async function handleMemoryAction(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("memory", request.method);
  const opened = await gate(ctx, request, deps, [], { method: "POST", allowOverCap: true });
  if (!opened.ok) return opened.response;
  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);
  const parsed = ActionSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;
  const store = managementStore(deps);
  if (!store) return unavailable(ctx, "DATABASE_URL is not set");
  const id = opened.student.id;
  ctx.note({ memory_action: req.action });

  try {
    if (req.action === "consent") {
      if (!recordSwitchedOn(deps.env)) return ctx.fail(404, "memory_not_available", "memory is not switched on", "memory_not_available");
      if (!req.attested) return ctx.fail(422, "attestation_required", "say who is agreeing", "attestation_required");
      if (req.notice_version !== NOTICE_VERSION) {
        return ctx.fail(409, "notice_outdated", "the consent text has changed; fetch it again", "notice_outdated");
      }
      await timedDb(ctx, () => store.grant(id, { givenBy: req.given_by, via: "app", noticeVersion: NOTICE_VERSION, noticeHash: noticeHash() }));
      logConsentChange(ctx, "memory_consent_granted", { given_by: req.given_by, via: "app", notice_version: NOTICE_VERSION });
      return ctx.respond(200, { ok: true }, "ok", "memory_consent_granted");
    }
    const erase = req.action === "erase" ? true : req.erase;
    const done: Deleted =
      req.action === "withdraw"
        ? await timedDb(ctx, () => store.withdraw(id, "app", NOTICE_VERSION, erase))
        : await timedDb(ctx, () => store.erase(id));
    if (req.action === "withdraw") logConsentChange(ctx, "memory_withdrawn", { via: "app", erased: erase, changed: done.withdrawn > 0 });
    if (erase) logConsentChange(ctx, "memory_erased", { hints: done.hints, attempts: done.attempts, notes: done.notes });
    return ctx.respond(200, { ok: true, ...deletedBody(done) }, "ok", req.action === "withdraw" ? "memory_withdrawn" : "memory_erased");
  } catch (err) {
    return unavailable(ctx, labelOf(err));
  }
}

// ---------------------------------------------------------------- the policy page (no sign-in, no database)

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Bold, and links with an http(s) address only. Input is escaped first.
function inline(s: string): string {
  return escapeHtml(s)
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>');
}

// A very small Markdown reader for the policy: headings, bullet lists, paragraphs, bold, links.
export function renderPolicyHtml(markdown: string): string {
  const out: string[] = [];
  let paragraph: string[] = [];
  let inList = false;
  const flush = () => {
    if (paragraph.length) out.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const closeList = () => {
    if (inList) out.push("</ul>");
    inList = false;
  };
  for (const raw of markdown.split("\n")) {
    const line = raw.trimEnd();
    const heading = /^(#{1,3}) (.+)$/.exec(line);
    if (heading) {
      flush();
      closeList();
      const level = (heading[1] ?? "#").length;
      out.push(`<h${level}>${inline(heading[2] ?? "")}</h${level}>`);
    } else if (line.startsWith("- ")) {
      flush();
      if (!inList) out.push("<ul>");
      inList = true;
      out.push(`<li>${inline(line.slice(2))}</li>`);
    } else if (line === "") {
      flush();
      closeList();
    } else {
      closeList();
      paragraph.push(line);
    }
  }
  flush();
  closeList();
  const style = "body{font:18px/1.55 -apple-system,system-ui,sans-serif;max-width:42rem;margin:2rem auto;padding:0 1rem;color:#222}h1,h2,h3{line-height:1.25}";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pencil Tutor privacy policy</title><style>${style}</style></head><body>${out.join("\n")}</body></html>`;
}

export function handlePrivacy(request: Request): Response {
  const ctx = new RequestCtx("privacy", request.method);
  if (request.method !== "GET") return ctx.fail(405, "method_not_allowed", "use GET", "method_not_allowed");
  const bytes = new TextEncoder().encode(renderPolicyHtml(PRIVACY_POLICY_MD));
  return ctx.respondBytes(bytes, "text/html; charset=utf-8", "ok", "privacy_policy");
}

export type { RecordStore };
