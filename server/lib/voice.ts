import type { Env } from "./config.js";

// The tutor's voice: ElevenLabs Eleven v4 Turbo, streamed. Sources (read 2026-11-14):
//  - model id `eleven_v4_turbo`: https://elevenlabs.io/docs/overview/models
//  - streaming text to speech `POST /v1/text-to-speech/{voice_id}/stream`, `xi-api-key` header, `output_format` query:
//    https://elevenlabs.io/docs/api-reference/text-to-speech/stream
//  - $0.04 per 1,000 characters for v4 Turbo: https://elevenlabs.io/pricing/api
// v4 Turbo has two voice settings, stability and similarity (no style or speed, no SSML):
// https://elevenlabs.io/docs/overview/capabilities/text-to-speech/eleven-v4

export const DEFAULT_ELEVEN_MODEL = "eleven_v4_turbo";
// Until Edward's own voice clone exists: the premade American male voice "Eric" (labelled "Smooth, Trustworthy",
// conversational, middle aged). Switch to the clone by setting ELEVENLABS_VOICE_ID in Vercel; no code change.
export const DEFAULT_ELEVEN_VOICE_ID = "cjVigY5qzO86Huf0OWal";
export const DEFAULT_ELEVEN_VOICE_NAME = "Eric (premade)";
// Raw 16-bit little-endian mono PCM at 24 kHz: no decoder on the iPad, plays as it arrives. OpenAI's `pcm` is the same format.
export const ELEVEN_OUTPUT_FORMAT = "pcm_24000";
export const AUDIO_FORMAT_LABEL = "pcm_s16le_24000";

const FIRST_AUDIO_TIMEOUT_MS = 6_000;
const WHOLE_STREAM_TIMEOUT_MS = 45_000;

export type ElevenSettings = { apiKey: string; voiceId: string; model: string; stability: number; similarity: number };

const unitNumber = (value: string | undefined, fallback: number): number => {
  const n = value === undefined || value.trim() === "" ? NaN : Number(value);
  return Number.isFinite(n) && n >= 0 && n <= 1 ? n : fallback;
};

// ElevenLabs is configured when ELEVENLABS_API_KEY is set. Without it every utterance goes to the OpenAI fallback.
export function elevenSettings(env: Env): ElevenSettings | undefined {
  const apiKey = env.ELEVENLABS_API_KEY?.trim();
  if (!apiKey) return undefined;
  return {
    apiKey,
    voiceId: env.ELEVENLABS_VOICE_ID?.trim() || DEFAULT_ELEVEN_VOICE_ID,
    model: env.ELEVENLABS_MODEL?.trim() || DEFAULT_ELEVEN_MODEL,
    stability: unitNumber(env.ELEVENLABS_STABILITY, 0.5),
    similarity: unitNumber(env.ELEVENLABS_SIMILARITY, 0.75),
  };
}

export function voiceSummary(env: Env) {
  const eleven = elevenSettings(env);
  return {
    provider: eleven ? "elevenlabs" : "openai",
    elevenlabs: {
      key_present: Boolean(eleven),
      model: env.ELEVENLABS_MODEL?.trim() || DEFAULT_ELEVEN_MODEL,
      voice_id: env.ELEVENLABS_VOICE_ID?.trim() || DEFAULT_ELEVEN_VOICE_ID,
      output_format: ELEVEN_OUTPUT_FORMAT,
    },
    fallback: ["openai", "device"],
  };
}

export type VoiceStream = {
  kind: "stream";
  firstChunk: Uint8Array;
  // The rest of the audio. `read()` resolves done:true at the end; `cancel()` stops the upstream request.
  reader: ReadableStreamDefaultReader<Uint8Array>;
};
export type VoiceFailure = { kind: "failed"; label: string };

// One seam: "start streaming this text as speech". Tests pass a fake; the real one is a plain fetch.
export interface VoiceGateway {
  stream(args: { settings: ElevenSettings; text: string }): Promise<VoiceStream | VoiceFailure>;
}

// The reason ElevenLabs refused, as a label. Its error body is JSON like {"detail":{"status":"quota_exceeded",...}}; only the
// short status word is kept (never the message, which can echo account details).
async function refusalLabel(response: Response): Promise<string> {
  const base = `elevenlabs_http_${response.status}`;
  try {
    const body = (await response.json()) as { detail?: { status?: unknown } | unknown };
    const detail = body.detail;
    const status = typeof detail === "object" && detail !== null ? (detail as { status?: unknown }).status : undefined;
    if (typeof status === "string" && /^[a-z_]{1,40}$/.test(status)) return `${base}_${status}`;
  } catch {
    // not JSON; the status code alone is the label
  }
  return base;
}

export const realVoice: VoiceGateway = {
  async stream({ settings, text }) {
    const controller = new AbortController();
    const wholeTimer = setTimeout(() => controller.abort(), WHOLE_STREAM_TIMEOUT_MS);
    const firstAudioTimer = setTimeout(() => controller.abort(), FIRST_AUDIO_TIMEOUT_MS);
    const stop = () => {
      clearTimeout(wholeTimer);
      clearTimeout(firstAudioTimer);
    };
    try {
      const url = `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(settings.voiceId)}/stream?output_format=${ELEVEN_OUTPUT_FORMAT}`;
      const response = await fetch(url, {
        method: "POST",
        headers: { "xi-api-key": settings.apiKey, "content-type": "application/json", accept: "application/octet-stream" },
        body: JSON.stringify({
          text,
          model_id: settings.model,
          language_code: "en",
          voice_settings: { stability: settings.stability, similarity_boost: settings.similarity },
        }),
        signal: controller.signal,
      });
      if (!response.ok) {
        stop();
        return { kind: "failed", label: await refusalLabel(response) };
      }
      if (!response.body) {
        stop();
        return { kind: "failed", label: "elevenlabs_no_body" };
      }
      const reader = response.body.getReader();
      const first = await reader.read();
      clearTimeout(firstAudioTimer);
      if (first.done || !first.value || first.value.length === 0) {
        stop();
        return { kind: "failed", label: "elevenlabs_empty_audio" };
      }
      // Wrap the reader so the whole-stream timer is cleared when the audio ends or the caller gives up.
      const wrapped = {
        read: async () => {
          const next = await reader.read();
          if (next.done) stop();
          return next;
        },
        cancel: async (reason?: unknown) => {
          stop();
          controller.abort();
          return reader.cancel(reason);
        },
      } as unknown as ReadableStreamDefaultReader<Uint8Array>;
      return { kind: "stream", firstChunk: first.value, reader: wrapped };
    } catch (err) {
      stop();
      const name = err instanceof Error ? err.name : "";
      if (name === "AbortError" || name === "TimeoutError") return { kind: "failed", label: "elevenlabs_timeout" };
      return { kind: "failed", label: `elevenlabs_error_${name || "unknown"}` };
    }
  },
};
