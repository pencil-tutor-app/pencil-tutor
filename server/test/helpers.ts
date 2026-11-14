import { MockLanguageModelV4 } from "ai/test";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import type { ModelFactory } from "../lib/models.js";
import { MemoryStudentStore } from "../lib/students-memory.js";
import type { StudentStore } from "../lib/students.js";
import type { VoiceGateway, VoiceStream, VoiceFailure } from "../lib/voice.js";

// A student code in the real format (8 characters from the code alphabet). It is the bearer credential in every test.
export const TOKEN = "K7MQ2XAB";
// Well formed but nobody has it.
export const UNKNOWN_CODE = "R4WZ9CHD";
// A fixed moment so the month (America/Vancouver) is the same on every run: 2026-11.
export const FIXED_NOW = new Date("2026-11-14T18:00:00Z");
export const TEST_MONTH = "2026-11-01";

// A store holding one student, TOKEN, with the default 8-hour cap and the live plan off.
export function testStore(options: { capSeconds?: number; planLive?: boolean; disabled?: boolean } = {}) {
  const store = new MemoryStudentStore();
  const id = store.add(TOKEN, options);
  return { store, id };
}

// A header-only PNG: the server reads signature and IHDR only; the model is mocked in tests.
export function makePng(width: number, height: number, totalBytes = 2000): string {
  const header = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header, 0);
  header.writeUInt32BE(13, 8);
  header.write("IHDR", 12, "ascii");
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  const pad = Buffer.alloc(Math.max(0, totalBytes - header.length), 7);
  return Buffer.concat([header, pad]).toString("base64");
}

export const line = (index: number) => ({ index, box: { x: 10, y: 40 * index, w: 300, h: 30 }, last_stroke_at: "2026-11-13T01:00:00Z" });

export function watchBody(overrides: Record<string, unknown> = {}) {
  return {
    session_id: "s1",
    problem_id: "u3-04",
    drawing_revision: 7,
    image_png_base64: makePng(800, 600),
    image_width: 800,
    image_height: 600,
    lines: [line(1), line(2), line(3)],
    history: [],
    client_time: "2026-11-13T01:00:05Z",
    ...overrides,
  };
}

export function askBody(overrides: Record<string, unknown> = {}) {
  return {
    session_id: "s1",
    problem_id: "u3-04",
    drawing_revision: 7,
    audio_base64: Buffer.from("fake m4a bytes").toString("base64"),
    image_png_base64: makePng(800, 600),
    ...overrides,
  };
}

export function speakBody(overrides: Record<string, unknown> = {}) {
  return { session_id: "s1", text: "Take another look at line two.", purpose: "hint", ...overrides };
}

export function post(path: string, body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  return new Request(`https://example.test${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

export type Reply = { status: number; json: Record<string, unknown> };
export async function reply(res: Response): Promise<Reply> {
  return { status: res.status, json: (await res.json()) as Record<string, unknown> };
}

// A fake provider: every language call returns `text`, and the prompts it received are kept for inspection.
export function fakeModels(text: string | (() => never)) {
  const prompts: string[] = [];
  const language = new MockLanguageModelV4({
    doGenerate: async (options) => {
      prompts.push(JSON.stringify(options.prompt));
      if (typeof text === "function") text();
      return {
        content: [{ type: "text", text: text as string }],
        finishReason: { unified: "stop", raw: "stop" },
        usage: {
          inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
          outputTokens: { total: 10, text: 10, reasoning: 0 },
        },
        warnings: [],
      };
    },
  });
  const models: ModelFactory = {
    language: () => language,
    transcription: () => ({
      specificationVersion: "v4",
      provider: "fake",
      modelId: "fake-stt",
      doGenerate: async () => ({
        text: "what do I do with the minus sign",
        segments: [],
        language: "en",
        durationInSeconds: 2,
        warnings: [],
        response: { timestamp: new Date(), modelId: "fake-stt" },
      }),
    }),
    speech: () => {
      throw new Error("no speech model expected in this test");
    },
  };
  return { models, prompts };
}

// A fake speech provider: returns `bytes`, or throws if `bytes` is a function. The call options it saw are kept.
export function fakeSpeech(bytes: Uint8Array | (() => never)) {
  const calls: { model: string; text: string; voice?: string; instructions?: string; outputFormat?: string }[] = [];
  const models: ModelFactory = {
    language: () => {
      throw new Error("no language model expected in this test");
    },
    transcription: () => {
      throw new Error("no transcription model expected in this test");
    },
    speech: (cfg) => ({
      specificationVersion: "v4",
      provider: "fake",
      modelId: cfg.model,
      doGenerate: async (options) => {
        calls.push({ model: cfg.model, text: options.text, voice: options.voice, instructions: options.instructions, outputFormat: options.outputFormat });
        if (typeof bytes === "function") bytes();
        return { audio: bytes as Uint8Array, warnings: [], response: { timestamp: new Date(), modelId: cfg.model } };
      },
    }),
  };
  return { models, calls };
}

export const liveEnv = (extra: Record<string, string | undefined> = {}) => ({
  APP_ACCESS_TOKEN: TOKEN,
  OPENAI_API_KEY: "sk-test-not-real",
  ...extra,
});

// A fake ElevenLabs: streams `chunks` (the first one is the first audio), or fails with `failure`. The calls it got are kept.
export function fakeVoice(result: Uint8Array[] | { failure: string }) {
  const calls: { voiceId: string; model: string; text: string }[] = [];
  const gateway: VoiceGateway = {
    async stream({ settings, text }): Promise<VoiceStream | VoiceFailure> {
      calls.push({ voiceId: settings.voiceId, model: settings.model, text });
      if (!Array.isArray(result)) return { kind: "failed", label: result.failure };
      const [first, ...rest] = result;
      let index = 0;
      const reader = {
        read: async () => (index < rest.length ? { done: false, value: rest[index++] as Uint8Array } : { done: true, value: undefined }),
        cancel: async () => {},
      } as unknown as ReadableStreamDefaultReader<Uint8Array>;
      return { kind: "stream", firstChunk: first as Uint8Array, reader };
    },
  };
  return { gateway, calls };
}

export function deps(
  env: Record<string, string | undefined>,
  models?: ModelFactory,
  extra: { store?: StudentStore; voice?: VoiceGateway; now?: () => Date } = {},
): Deps {
  return {
    env,
    students: extra.store ?? testStore().store,
    voice: extra.voice,
    now: extra.now ?? (() => FIXED_NOW),
    models:
      models ??
      ({
        language: () => {
          throw new Error("no model expected in this test");
        },
        transcription: () => {
          throw new Error("no model expected in this test");
        },
        speech: () => {
          throw new Error("no model expected in this test");
        },
      } satisfies ModelFactory),
  };
}

export function captureLogs() {
  const lines: Record<string, unknown>[] = [];
  const raw: string[] = [];
  const restore = setLogSink((l) => {
    raw.push(l);
    lines.push(JSON.parse(l));
  });
  return { lines, raw, restore };
}
