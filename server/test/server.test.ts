import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { handleAsk } from "../lib/ask.js";
import { handleHealth } from "../lib/health.js";
import { handleWatch } from "../lib/watch.js";
import {
  askBody,
  captureLogs,
  deps,
  fakeModels,
  line,
  liveEnv,
  makePng,
  post,
  reply,
  TOKEN,
  UNKNOWN_CODE,
  watchBody,
} from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const SCRIPTED = { APP_ACCESS_TOKEN: TOKEN, TUTOR_SCRIPTED: "1" };

describe("auth", () => {
  it("answers 401 with no code, a malformed code, a wrong scheme, and a well formed code nobody has", async () => {
    const d = deps(SCRIPTED);
    assert.equal((await handleWatch(post("/api/watch", watchBody(), null), d)).status, 401);
    assert.equal((await handleWatch(post("/api/watch", watchBody(), "nope"), d)).status, 401);
    const basic = new Request("https://example.test/api/watch", { method: "POST", headers: { authorization: `Basic ${TOKEN}` }, body: "{}" });
    assert.equal((await handleWatch(basic, d)).status, 401);
    assert.equal((await handleAsk(post("/api/ask", askBody(), null), d)).status, 401);
    assert.equal((await handleWatch(post("/api/watch", watchBody(), UNKNOWN_CODE), d)).status, 401);
    const labels = logs.lines.map((l) => l.outcome);
    assert.deepEqual(labels, [
      "unauthorized:missing_header",
      "unauthorized:malformed_code",
      "unauthorized:bad_scheme",
      "unauthorized:missing_header",
      "unauthorized:unknown_code",
    ]);
  });

  it("the old shared token is not a credential any more", async () => {
    const d = deps({ ...SCRIPTED, APP_ACCESS_TOKEN: "an-old-shared-token-value" });
    const r = await reply(await handleWatch(post("/api/watch", watchBody(), "an-old-shared-token-value"), d));
    assert.deepEqual([r.status, r.json.error, r.json.reason], [401, "unauthorized", "malformed_code"]);
  });

  it("lets health through without a token", async () => {
    const res = handleHealth(new Request("https://example.test/api/health"), { OPENAI_API_KEY: "sk-test" });
    const r = await reply(res);
    assert.equal(r.status, 200);
    assert.equal(r.json.openai_key_present, true);
    assert.equal(r.json.gemini_key_present, false);
    assert.equal(JSON.stringify(r.json).includes("sk-test"), false, "health must never print a key");
  });

  it("answers 401 on an unauthenticated GET, not 405", async () => {
    const res = await handleWatch(new Request("https://example.test/api/watch"), deps(SCRIPTED));
    assert.equal(res.status, 401);
  });
});

describe("scripted mode", () => {
  it("interrupts the planted problem on line 2, once, and waits otherwise", async () => {
    const d = deps(SCRIPTED);
    const first = await reply(await handleWatch(post("/api/watch", watchBody()), d));
    assert.equal(first.status, 200);
    assert.equal(first.json.action, "interrupt");
    assert.equal(first.json.line, 2);
    assert.equal(typeof first.json.hint_spoken, "string");
    assert.equal(typeof first.json.hint_written, "string");
    assert.equal(first.json.model, "scripted");

    const again = await reply(
      await handleWatch(post("/api/watch", watchBody({ history: [{ at: "t", action: "interrupt", line: 2, hint_written: "x" }] })), d),
    );
    assert.equal(again.json.action, "wait");

    const clean = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" })), d));
    assert.equal(clean.json.action, "wait");
    assert.equal(clean.json.line, null);
    assert.equal(clean.json.hint_spoken, null);

    const tooFewLines = await reply(await handleWatch(post("/api/watch", watchBody({ lines: [line(1)] })), d));
    assert.equal(tooFewLines.json.action, "wait");
  });

  it("answers /api/ask from the script with no key", async () => {
    const r = await reply(await handleAsk(post("/api/ask", askBody()), deps(SCRIPTED)));
    assert.equal(r.status, 200);
    assert.equal(r.json.transcript, "scripted question");
    assert.equal(typeof r.json.answer_text, "string");
    assert.equal(r.json.drawing_revision, 7);
  });

  it("refuses to turn on when VERCEL_ENV is production", async () => {
    const env = { ...SCRIPTED, VERCEL_ENV: "production" };
    const w = await reply(await handleWatch(post("/api/watch", watchBody()), deps(env)));
    assert.equal(w.status, 503);
    assert.equal(w.json.error, "missing_key");
    const a = await reply(await handleAsk(post("/api/ask", askBody()), deps(env)));
    assert.equal(a.status, 503);
    const h = await reply(handleHealth(new Request("https://example.test/api/health"), env));
    assert.equal(h.json.scripted, false);
    assert.equal(h.json.scripted_refused_in_production, true);
    assert.ok(logs.lines.some((l) => l.outcome === "scripted_refused" && l.level === "error"), "the refusal is logged");
  });

  it("still validates the request (scripted mode is not a bypass)", async () => {
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ drawing_revision: undefined })), deps(SCRIPTED)));
    assert.equal(r.status, 422);
  });
});

describe("missing key", () => {
  const noKey = { APP_ACCESS_TOKEN: TOKEN };

  it("watch and ask answer 503 naming the OpenAI variable", async () => {
    const w = await reply(await handleWatch(post("/api/watch", watchBody()), deps(noKey)));
    assert.deepEqual([w.status, w.json.error, w.json.reason], [503, "missing_key", "OPENAI_API_KEY is not set"]);
    const a = await reply(await handleAsk(post("/api/ask", askBody()), deps(noKey)));
    assert.deepEqual([a.status, a.json.error, a.json.reason], [503, "missing_key", "OPENAI_API_KEY is not set"]);
  });

  it("names the Gemini variable when the provider is google", async () => {
    const env = { ...noKey, WATCH_PROVIDER: "google", ASK_PROVIDER: "google", OPENAI_API_KEY: "sk-present" };
    const w = await reply(await handleWatch(post("/api/watch", watchBody()), deps(env)));
    assert.deepEqual([w.status, w.json.reason], [503, "GEMINI_API_KEY is not set"]);
    const a = await reply(await handleAsk(post("/api/ask", askBody()), deps(env)));
    assert.deepEqual([a.status, a.json.reason], [503, "GEMINI_API_KEY is not set"]);
  });

  it("503 comes before body validation, so an empty smoke call sees it", async () => {
    const r = await reply(await handleWatch(post("/api/watch", {}), deps(noKey)));
    assert.equal(r.status, 503);
  });

  it("rejects an unknown provider with a plain 503 bad_config", async () => {
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps({ ...liveEnv(), WATCH_PROVIDER: "acme" })));
    assert.deepEqual([r.status, r.json.error], [503, "bad_config"]);
  });
});

describe("request validation", () => {
  const d = () => deps(SCRIPTED);

  it("rejects an image over 400 KB with 422", async () => {
    const big = makePng(800, 600, 450 * 1024);
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ image_png_base64: big })), d()));
    assert.equal(r.status, 422);
    assert.equal(r.json.error, "invalid_image");
    assert.equal(r.json.reason, "image_over_400_KB");
    const a = await reply(await handleAsk(post("/api/ask", askBody({ image_png_base64: big })), d()));
    assert.equal(a.status, 422);
  });

  it("rejects a longest side over 1024 px, accepts exactly 1024", async () => {
    const tall = await reply(await handleWatch(post("/api/watch", watchBody({ image_png_base64: makePng(600, 1025) })), d()));
    assert.deepEqual([tall.status, tall.json.reason], [422, "image_longest_side_over_1024_px"]);
    const ok = await reply(await handleWatch(post("/api/watch", watchBody({ image_png_base64: makePng(1024, 768) })), d()));
    assert.equal(ok.status, 200);
  });

  it("rejects something that is not a PNG or JPEG", async () => {
    const junk = Buffer.from("this is not an image at all, just text").toString("base64");
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ image_png_base64: junk })), d()));
    assert.deepEqual([r.status, r.json.reason], [422, "image_not_png_or_jpeg"]);
  });

  it("echoes drawing_revision exactly and requires it", async () => {
    for (const rev of [0, 1, 123456]) {
      const r = await reply(await handleWatch(post("/api/watch", watchBody({ drawing_revision: rev })), d()));
      assert.equal(r.json.drawing_revision, rev);
    }
    const missing = watchBody();
    delete (missing as Record<string, unknown>).drawing_revision;
    const r = await reply(await handleWatch(post("/api/watch", missing), d()));
    assert.equal(r.status, 422);
  });

  it("takes exactly one problem id, and it must be in the bank", async () => {
    const many = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: ["u3-01", "u3-04"] })), d()));
    assert.equal(many.status, 422);
    const unknown = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "u9-99" })), d()));
    assert.deepEqual([unknown.status, unknown.json.error], [422, "unknown_problem"]);
  });

  it("answers 400 for a body that is not JSON", async () => {
    const req = new Request("https://example.test/api/watch", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` }, body: "{nope" });
    assert.equal((await handleWatch(req, d())).status, 400);
  });
});

describe("watch with a model", () => {
  const goodInterrupt = {
    action: "interrupt",
    line: 2,
    reason: "sign error when expanding the bracket",
    hint_spoken: "Take another look at line two and check the signs.",
    hint_written: "Check the signs",
  };

  it("passes a valid interrupt through", async () => {
    const { models } = fakeModels(JSON.stringify(goodInterrupt));
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.equal(r.json.action, "interrupt");
    assert.equal(r.json.line, 2);
    assert.equal(r.json.drawing_revision, 7);
    assert.equal(r.json.model, "gpt-6.1-sol");
  });

  it("turns malformed model output into a wait with a logged reason, never a crash", async () => {
    for (const bad of ["this is not json at all", "{\"action\":\"shout\"}", "{\"action\":\"interrupt\"}", ""]) {
      logs.lines.length = 0;
      const { models } = fakeModels(bad);
      const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models)));
      assert.equal(r.status, 200, `status for ${JSON.stringify(bad)}`);
      assert.equal(r.json.action, "wait");
      assert.equal(r.json.line, null);
      assert.equal(r.json.hint_spoken, null);
      assert.equal(r.json.drawing_revision, 7);
      const entry = logs.lines.at(-1);
      assert.equal(entry?.action, "wait");
      assert.match(String(entry?.reason), /malformed|model_output/);
    }
  });

  it("waits when the model names a line that is not on the page", async () => {
    const { models } = fakeModels(JSON.stringify({ ...goodInterrupt, line: 9 }));
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models)));
    assert.equal(r.json.action, "wait");
    assert.equal(logs.lines.at(-1)?.reason, "line_not_in_page");
  });

  it("waits when the hint would hand over the final answer", async () => {
    const leaky = { ...goodInterrupt, hint_spoken: "You should end up with p = -4 here." };
    const { models } = fakeModels(JSON.stringify(leaky));
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models)));
    assert.equal(r.json.action, "wait");
    assert.equal(logs.lines.at(-1)?.reason, "hint_reveals_answer");
  });

  it("sends only the last 10 history entries to the model", async () => {
    const history = Array.from({ length: 25 }, (_, i) => ({ at: `t${i}`, action: "wait", line: null, hint_written: null }));
    const { models, prompts } = fakeModels(JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null }));
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ history })), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    const sent = prompts.join("");
    assert.ok(sent.includes("t24") && sent.includes("t15"), "newest 10 are sent");
    assert.ok(!sent.includes("t14"), "older entries are not sent");
    assert.equal(logs.lines.at(-1)?.history_in, 25);
    assert.equal(logs.lines.at(-1)?.history_used, 10);
  });

  it("answers 502 when the provider call itself fails", async () => {
    const { models } = fakeModels(() => {
      throw new Error("boom");
    });
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(liveEnv(), models)));
    assert.deepEqual([r.status, r.json.error], [502, "model_error"]);
  });

  it("uses WATCH_PROVIDER, WATCH_MODEL from the environment", async () => {
    const { models } = fakeModels(JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null }));
    const env = liveEnv({ WATCH_PROVIDER: "google", WATCH_MODEL: "gemini-3.8-flash", GEMINI_API_KEY: "g-test" });
    const r = await reply(await handleWatch(post("/api/watch", watchBody()), deps(env, models)));
    assert.equal(r.json.model, "gemini-3.8-flash");
    assert.equal(logs.lines.at(-1)?.provider, "google");
  });
});

describe("ask with a model", () => {
  it("transcribes, answers with the page in view, and echoes the revision", async () => {
    const { models, prompts } = fakeModels("Try distributing the minus sign to both terms inside the bracket.");
    const r = await reply(await handleAsk(post("/api/ask", askBody()), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    assert.equal(r.json.transcript, "what do I do with the minus sign");
    assert.match(String(r.json.answer_text), /distributing/);
    assert.equal(r.json.drawing_revision, 7);
    assert.ok(prompts.join("").includes("what do I do with the minus sign"), "the transcript reaches the model");
  });
});

describe("logging", () => {
  it("writes one structured line per request and never logs content, hints or tokens", async () => {
    const { models } = fakeModels(
      JSON.stringify({
        action: "interrupt",
        line: 2,
        reason: "SECRET-REASON-TEXT",
        hint_spoken: "SECRET-SPOKEN-HINT",
        hint_written: "SECRET-WRITTEN-HINT",
      }),
    );
    const image = makePng(800, 600);
    await handleWatch(post("/api/watch", watchBody({ image_png_base64: image })), deps(liveEnv(), models));
    await handleWatch(post("/api/watch", watchBody(), "wrong-token"), deps(liveEnv(), models));
    assert.equal(logs.lines.length, 2, "exactly one line per request");
    const ok = logs.lines[0]!;
    for (const key of ["request_id", "endpoint", "provider", "model", "latency_ms", "image_bytes", "line_count", "action", "line", "outcome", "status"]) {
      assert.ok(key in ok, `log line has ${key}`);
    }
    assert.equal(ok.outcome, "ok");
    assert.equal(ok.reason, "model_interrupt");
    const all = logs.raw.join("\n");
    for (const secret of ["SECRET-", image.slice(0, 40), TOKEN, "sk-test-not-real", "wrong-token"]) {
      assert.ok(!all.includes(secret), `log must not contain ${secret}`);
    }
  });
});
