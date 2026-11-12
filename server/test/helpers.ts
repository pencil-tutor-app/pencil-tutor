import { MockLanguageModelV4 } from "ai/test";
import type { Deps } from "../lib/gate.js";
import { setLogSink } from "../lib/log.js";
import type { ModelFactory } from "../lib/models.js";

export const TOKEN = "test-token-123";

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
  };
  return { models, prompts };
}

export const liveEnv = (extra: Record<string, string | undefined> = {}) => ({
  APP_ACCESS_TOKEN: TOKEN,
  OPENAI_API_KEY: "sk-test-not-real",
  ...extra,
});

export function deps(env: Record<string, string | undefined>, models?: ModelFactory): Deps {
  return {
    env,
    models:
      models ??
      ({
        language: () => {
          throw new Error("no model expected in this test");
        },
        transcription: () => {
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
