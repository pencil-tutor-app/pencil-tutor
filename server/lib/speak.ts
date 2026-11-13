import { z } from "zod";
import { speakSettings } from "./config.js";
import { defaultDeps, gate, issueReason, type Deps } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { runSpeech } from "./models.js";

export const MAX_SPEAK_CHARS = 600;

// The client sends a short label such as "hint", "answer" or "check_ok". It goes into the log, so it is
// restricted to a plain label: free text here would be a way to put content in the logs.
const PURPOSE_LABEL = /^[a-z0-9_]{1,40}$/;

const SpeakRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  text: z
    .string()
    .min(1, "text must be 1 to 600 characters")
    .max(MAX_SPEAK_CHARS, "text must be 1 to 600 characters")
    .refine((t) => t.trim().length > 0, "text must not be blank"),
  purpose: z.string().regex(PURPOSE_LABEL, "purpose must be a short lowercase label").optional(),
});

// A silent MPEG-1 Layer III stream: 4 frames of 417 bytes (header FF FB 90 00 = 128 kbps, 44.1 kHz, stereo,
// then zeros). Valid for any decoder, about 0.1 s long. Used by scripted mode so tests never call OpenAI.
export const SCRIPTED_MP3: Uint8Array = (() => {
  const frame = new Uint8Array(417);
  frame.set([0xff, 0xfb, 0x90, 0x00]);
  const out = new Uint8Array(frame.length * 4);
  for (let i = 0; i < 4; i += 1) out.set(frame, i * frame.length);
  return out;
})();

// POST /api/speak: text in, mp3 bytes out. Same order as /api/ask: auth, method, key (or scripted), body.
export async function handleSpeak(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("speak", request.method);

  const opened = gate(ctx, request, deps, ["speak"]);
  if (!opened.ok) return opened.response;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = SpeakRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;
  // Sizes and labels only. The text itself is never logged.
  ctx.note({ text_chars: req.text.length, purpose: req.purpose ?? "none" });

  if (opened.scripted) {
    ctx.note({ audio_bytes: SCRIPTED_MP3.length });
    return ctx.respondBytes(SCRIPTED_MP3, "audio/mpeg", "ok", "scripted_audio");
  }

  const cfg = opened.configs.speak!;
  const { voice, instructions } = speakSettings(deps.env);
  ctx.note({ voice });

  const spoken = await runSpeech({
    model: deps.models.speech(cfg, opened.keys.speak!),
    text: req.text,
    voice,
    instructions,
  });
  if (spoken.kind === "failed") return ctx.fail(spoken.status, spoken.error, spoken.label, `${spoken.error}:${spoken.label}`);
  if (spoken.bytes.length === 0) return ctx.fail(502, "model_error", "empty_audio", "model_error:empty_audio");

  ctx.note({ audio_bytes: spoken.bytes.length });
  return ctx.respondBytes(spoken.bytes, "audio/mpeg", "ok", "spoken");
}
