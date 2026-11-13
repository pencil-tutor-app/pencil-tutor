import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createOpenAI } from "@ai-sdk/openai";
import {
  APICallError,
  NoObjectGeneratedError,
  NoOutputGeneratedError,
  Output,
  generateSpeech,
  generateText,
  transcribe,
  type LanguageModel,
  type SpeechModel,
  type TranscriptionModel,
} from "ai";
import type { RoleConfig } from "./config.js";
import type { ImageInfo } from "./image.js";
import { ASK_POLICY, WATCH_POLICY, WatchDecisionSchema } from "./policy.js";

// The two seams tests replace: how a provider config becomes an AI SDK model.
export interface ModelFactory {
  language(cfg: RoleConfig, apiKey: string): LanguageModel;
  transcription(cfg: RoleConfig, apiKey: string): TranscriptionModel;
  speech(cfg: RoleConfig, apiKey: string): SpeechModel;
}

export const realModels: ModelFactory = {
  language(cfg, apiKey) {
    return cfg.provider === "openai" ? createOpenAI({ apiKey })(cfg.model) : createGoogleGenerativeAI({ apiKey })(cfg.model);
  },
  transcription(cfg, apiKey) {
    return cfg.provider === "openai"
      ? createOpenAI({ apiKey }).transcription(cfg.model)
      : createGoogleGenerativeAI({ apiKey }).transcription(cfg.model);
  },
  // Text-to-speech is OpenAI only; the speak role never resolves to another provider.
  speech(cfg, apiKey) {
    return createOpenAI({ apiKey }).speech(cfg.model);
  },
};

export type ModelFailure = { kind: "failed"; status: 502 | 504; error: "model_error" | "model_timeout"; label: string };
export type Malformed = { kind: "malformed"; label: string };

// Turns a thrown provider error into a status and a label. Never copies the message: provider messages can echo keys.
export function classifyFailure(err: unknown): ModelFailure {
  const name = err instanceof Error ? err.name : "";
  if (name === "TimeoutError" || name === "AbortError") {
    return { kind: "failed", status: 504, error: "model_timeout", label: "provider_timeout" };
  }
  if (APICallError.isInstance(err)) {
    return { kind: "failed", status: 502, error: "model_error", label: `provider_http_${err.statusCode ?? "unknown"}` };
  }
  return { kind: "failed", status: 502, error: "model_error", label: `provider_error_${name || "unknown"}` };
}

const WATCH_TIMEOUT_MS = 40_000;
const ASK_TIMEOUT_MS = 30_000;
const STT_TIMEOUT_MS = 20_000;
const SPEAK_TIMEOUT_MS = 20_000;

export async function runSpeech(args: {
  model: SpeechModel;
  text: string;
  voice: string;
  instructions: string;
}): Promise<{ kind: "audio"; bytes: Uint8Array } | ModelFailure> {
  try {
    const result = await generateSpeech({
      model: args.model,
      text: args.text,
      voice: args.voice,
      outputFormat: "mp3",
      instructions: args.instructions,
      abortSignal: AbortSignal.timeout(SPEAK_TIMEOUT_MS),
      maxRetries: 1,
    });
    return { kind: "audio", bytes: result.audio.uint8Array };
  } catch (err) {
    return classifyFailure(err);
  }
}

export async function runWatchModel(args: {
  model: LanguageModel;
  promptText: string;
  image: ImageInfo;
}): Promise<{ kind: "decision"; raw: unknown } | Malformed | ModelFailure> {
  try {
    const result = await generateText({
      model: args.model,
      system: WATCH_POLICY,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: args.promptText },
            { type: "file", data: args.image.data, mediaType: args.image.mediaType },
          ],
        },
      ],
      output: Output.object({ schema: WatchDecisionSchema }),
      abortSignal: AbortSignal.timeout(WATCH_TIMEOUT_MS),
      maxRetries: 1,
    });
    return { kind: "decision", raw: result.output };
  } catch (err) {
    if (NoObjectGeneratedError.isInstance(err) || NoOutputGeneratedError.isInstance(err)) {
      return { kind: "malformed", label: "model_output_not_valid_json_for_schema" };
    }
    return classifyFailure(err);
  }
}

// Reads the page picture and answers in words. /api/ask uses it with ASK_POLICY; /api/consult (the Live delegation
// target) reuses it with CONSULT_POLICY, so both go through the same image handling, timeout and failure labels.
export async function runAskModel(args: {
  model: LanguageModel;
  promptText: string;
  image: ImageInfo;
  system?: string;
}): Promise<{ kind: "answer"; text: string } | ModelFailure> {
  try {
    const result = await generateText({
      model: args.model,
      system: args.system ?? ASK_POLICY,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: args.promptText },
            { type: "file", data: args.image.data, mediaType: args.image.mediaType },
          ],
        },
      ],
      abortSignal: AbortSignal.timeout(ASK_TIMEOUT_MS),
      maxRetries: 1,
    });
    return { kind: "answer", text: result.text.trim() };
  } catch (err) {
    return classifyFailure(err);
  }
}

export async function runTranscription(args: {
  model: TranscriptionModel;
  audio: Buffer;
}): Promise<{ kind: "transcript"; text: string } | ModelFailure> {
  try {
    const result = await transcribe({
      model: args.model,
      audio: args.audio,
      abortSignal: AbortSignal.timeout(STT_TIMEOUT_MS),
      maxRetries: 1,
    });
    return { kind: "transcript", text: result.text.trim() };
  } catch (err) {
    return classifyFailure(err);
  }
}
