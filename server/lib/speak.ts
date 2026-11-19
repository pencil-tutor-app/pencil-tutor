import { z } from "zod";
import { apiKeyFor, roleConfig, speakSettings } from "./config.js";
import { countText, speechActualMicros, speechReserve } from "./free-config.js";
import { paidCall, recordElevenChars, refuse } from "./free-spend.js";
import { defaultDeps, gate, issueReason, timedDb, type Deps, type GateOpen } from "./gate.js";
import { RequestCtx, readJson } from "./http.js";
import { logLine } from "./log.js";
import { runSpeech } from "./models.js";
import { AUDIO_FORMAT_LABEL, elevenSettings, realVoice, type VoiceStream } from "./voice.js";

export const MAX_SPEAK_CHARS = 600;

// The client sends a short label such as "hint", "answer" or "check_ok". It goes into the log, so it is
// restricted to a plain label: free text here would be a way to put content in the logs.
const PURPOSE_LABEL = /^[a-z0-9_]{1,40}$/;

// These two purposes are the fixed allowance announcements. The server writes the sentence itself (the client sends no text),
// so they are allowed even when the month's hours are used up without opening a free text-to-speech door.
const NOTICE_PURPOSES = new Set(["allowance_low", "allowance_used_up"]);

const SpeakRequestSchema = z.object({
  session_id: z.string().max(100).optional(),
  text: z
    .string()
    .max(MAX_SPEAK_CHARS, "text must be 1 to 600 characters")
    .refine((t) => t.trim().length > 0, "text must not be blank")
    .optional(),
  purpose: z.string().regex(PURPOSE_LABEL, "purpose must be a short lowercase label").optional(),
});

// 0.1 s of silence in the wire format (16-bit little-endian mono PCM at 24 kHz). Scripted mode returns it so tests never call a provider.
export const SCRIPTED_PCM: Uint8Array = new Uint8Array(24_000 * 2 * 0.1);

export function noticeText(purpose: string, remainingMinutes: number): string {
  if (purpose === "allowance_used_up") return "This month's tutoring hours are used up. They start fresh on the 1st.";
  if (remainingMinutes < 1) return "You have less than a minute left this month.";
  return `You have about ${remainingMinutes} ${remainingMinutes === 1 ? "minute" : "minutes"} left this month.`;
}

// POST /api/speak: text in, a stream of raw PCM audio out. The voice is ElevenLabs Eleven v4 Turbo; if ElevenLabs cannot
// start (no key, quota, error, slow), the same text goes to OpenAI text-to-speech and comes back in the same PCM format; if that
// fails too the client uses the device voice. Every fallback is logged with its reason.
export async function handleSpeak(request: Request, deps: Deps = defaultDeps()): Promise<Response> {
  const ctx = new RequestCtx("speak", request.method);

  const opened = await gate(ctx, request, deps, [], { allowOverCap: true });
  if (!opened.ok) return opened.response;
  const allowance = ctx.allowance!;

  const body = await readJson(request);
  if (!body.ok) return ctx.fail(body.status, body.error, body.reason);

  const parsed = SpeakRequestSchema.safeParse(body.value);
  if (!parsed.success) return ctx.fail(422, "invalid_request", issueReason(parsed.error), "invalid_request");
  const req = parsed.data;
  const purpose = req.purpose ?? "none";
  const isNotice = NOTICE_PURPOSES.has(purpose);

  if (allowance.state === "used_up" && !isNotice) {
    return ctx.fail(403, "hours_used_up", "this month's hours are used up", "hours_used_up");
  }
  const text = isNotice ? noticeText(purpose, allowance.remaining_minutes) : req.text;
  if (!text) return ctx.fail(422, "invalid_request", "text: text must be 1 to 600 characters", "invalid_request");
  // Sizes and labels only. The text itself is never logged.
  ctx.note({ text_chars: text.length, purpose });

  if (opened.scripted) {
    ctx.note({ audio_bytes: SCRIPTED_PCM.length, provider: "scripted" });
    return ctx.respondBytes(SCRIPTED_PCM, "application/octet-stream", "ok", "scripted_audio", {
      "x-audio-format": AUDIO_FORMAT_LABEL,
      "x-voice-provider": "scripted",
    });
  }

  const eleven = elevenSettings(deps.env);
  const openaiKey = apiKeyFor("openai", deps.env);
  if (!eleven && !openaiKey) {
    return ctx.fail(503, "missing_key", "ELEVENLABS_API_KEY is not set", "missing_key");
  }

  let fallbackReason: string | undefined;
  if (eleven) {
    const started = await (deps.voice ?? realVoice).stream({ settings: eleven, text });
    if (started.kind === "stream") return streamed(ctx, opened, deps, started, text.length, eleven.voiceId, purpose);
    fallbackReason = started.label;
  } else {
    fallbackReason = "elevenlabs_key_not_set";
  }

  // From here the voice is OpenAI's. Say why ElevenLabs was skipped.
  logLine("warn", {
    request_id: ctx.id,
    endpoint: "speak",
    student: ctx.fields.student as string,
    outcome: "voice_fallback",
    reason: fallbackReason,
    from: "elevenlabs",
    to: openaiKey ? "openai" : "device",
    text_chars: text.length,
  });
  if (!openaiKey) {
    return ctx.fail(502, "model_error", fallbackReason, `model_error:${fallbackReason}`);
  }

  const cfg = roleConfig("speak", deps.env);
  const { voice, instructions } = speakSettings(deps.env);
  ctx.note({ provider: "openai", model: cfg.model, voice, voice_fallback: fallbackReason });
  const counted = countCharacters(ctx, opened, text.length, "openai");
  // For a free code this OpenAI call costs money, so it is metered (reserve before, settle after): lib/free-spend.ts.
  const paid = await paidCall(ctx, deps.env, opened, {
    kind: "speech_fallback",
    reserve: () => speechReserve(cfg.model, text.length),
    run: () => runSpeech({ model: deps.models.speech(cfg, openaiKey), text, voice, instructions }),
    count: (out, reserve) =>
      out.kind === "failed"
        ? countText(undefined, out.label, reserve)
        : { micros: speechActualMicros(cfg.model, out.bytes.length) ?? reserve.perAttempt, basis: "estimated" },
  });
  const monthTotal = await counted;
  if (!paid.ok) return refuse(ctx, paid.refusal);
  const spoken = paid.value;
  if (monthTotal !== null) ctx.note({ tts_chars_month: monthTotal });
  if (spoken.kind === "failed") return ctx.fail(spoken.status, spoken.error, spoken.label, `${spoken.error}:${spoken.label}`);
  if (spoken.bytes.length === 0) return ctx.fail(502, "model_error", "empty_audio", "model_error:empty_audio");

  ctx.note({ audio_bytes: spoken.bytes.length });
  return ctx.respondBytes(spoken.bytes, "application/octet-stream", "ok", "spoken_fallback", {
    "x-audio-format": AUDIO_FORMAT_LABEL,
    "x-voice-provider": "openai",
    "x-voice-fallback": fallbackReason,
  });
}

// Adds this utterance's characters to the student's month. A failure is logged as an error and never stops the audio.
// Resolves to the month's running total, or null when it could not be recorded.
async function countCharacters(ctx: RequestCtx, opened: GateOpen, chars: number, provider: "elevenlabs" | "openai"): Promise<number | null> {
  try {
    // ElevenLabs is a flat plan: for a free code its characters are only added to the month's information-only counter (0 dollars).
    const [total] = await Promise.all([
      timedDb(ctx, () => opened.store.addSpeech(opened.student.id, opened.month, chars, provider)),
      provider === "elevenlabs" ? recordElevenChars(ctx, opened, chars) : Promise.resolve(),
    ]);
    return total;
  } catch (err) {
    logLine("error", {
      request_id: ctx.id,
      endpoint: "speak",
      student: ctx.fields.student as string,
      outcome: "chars_not_recorded",
      reason: err instanceof Error ? (err as { label?: string }).label ?? err.name : "unknown",
    });
    return null;
  }
}

// The ElevenLabs audio is already flowing: hand the first chunk to the client at once and relay the rest as it arrives.
function streamed(
  ctx: RequestCtx,
  opened: GateOpen,
  deps: Deps,
  started: VoiceStream,
  textChars: number,
  voiceId: string,
  purpose: string,
): Response {
  const { firstChunk, reader } = started;
  const counted = countCharacters(ctx, opened, textChars, "elevenlabs");
  const startedAt = ctx.startedAt;
  let bytes = firstChunk.length;
  let sentFirst = false;
  const student = ctx.fields.student as string;
  const requestId = ctx.id;
  const model = elevenSettings(deps.env)?.model ?? "";

  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (!sentFirst) {
        sentFirst = true;
        controller.enqueue(firstChunk);
        return;
      }
      try {
        const next = await reader.read();
        if (next.done) {
          const monthTotal = await counted;
          logLine("info", {
            request_id: requestId,
            endpoint: "speak",
            student,
            outcome: "stream_done",
            reason: "audio_complete",
            provider: "elevenlabs",
            text_chars: textChars,
            audio_bytes: bytes,
            total_ms: Date.now() - startedAt,
            tts_chars_month: monthTotal,
          });
          controller.close();
          return;
        }
        bytes += next.value.length;
        controller.enqueue(next.value);
      } catch (err) {
        logLine("error", {
          request_id: requestId,
          endpoint: "speak",
          student,
          outcome: "stream_failed",
          reason: `elevenlabs_stream_${err instanceof Error ? err.name : "error"}`,
          audio_bytes: bytes,
          total_ms: Date.now() - startedAt,
        });
        controller.error(err);
      }
    },
    async cancel() {
      logLine("warn", {
        request_id: requestId,
        endpoint: "speak",
        student,
        outcome: "stream_cancelled",
        reason: "client_closed_before_audio_finished",
        audio_bytes: bytes,
        total_ms: Date.now() - startedAt,
      });
      await reader.cancel();
    },
  });

  ctx.note({ provider: "elevenlabs", model, voice_id: voiceId, audio_format: AUDIO_FORMAT_LABEL, purpose });
  return ctx.respondStream(body, "application/octet-stream", "ok", "streaming", {
    "x-audio-format": AUDIO_FORMAT_LABEL,
    "x-voice-provider": "elevenlabs",
  });
}
