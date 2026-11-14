import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { roleConfig } from "../lib/config.js";
import { handleConsult } from "../lib/consult.js";
import { configForLevel } from "../lib/gate.js";
import { RequestCtx } from "../lib/http.js";
import { estimateCostUsd, rateFor } from "../lib/pricing.js";
import { levelOf, findProblem } from "../lib/problems.js";
import { providerOptionsFor } from "../lib/models.js";
import { reportUsage } from "../lib/usage.js";
import { handleWatch } from "../lib/watch.js";
import { EMPTY_USAGE } from "../lib/students.js";
import { captureLogs, deps, fakeModels, FIXED_NOW, liveEnv, post, reply, testStore, TEST_MONTH, watchBody, TOKEN } from "./helpers.js";

let logs: ReturnType<typeof captureLogs>;
beforeEach(() => {
  logs = captureLogs();
});
afterEach(() => logs.restore());

const usage = (input: number, cached: number, output: number, reasoning: number) => ({
  inputTokens: input,
  inputTokenDetails: { noCacheTokens: input - cached, cacheReadTokens: cached, cacheWriteTokens: undefined },
  outputTokens: output,
  outputTokenDetails: { textTokens: output - reasoning, reasoningTokens: reasoning },
  totalTokens: input + output,
});

describe("price table", () => {
  it("prices cached input at the cached rate and counts reasoning inside output", () => {
    // gpt-6.1-sol: $2 in, $0.10 cached, $10 out per million. 1000 input of which 400 cached, 500 output.
    const cost = estimateCostUsd("gpt-6.1-sol", { input: 1000, cachedInput: 400, output: 500 }, new Date("2026-11-14"));
    assert.ok(Math.abs((cost ?? 0) - (600 * 2 + 400 * 0.1 + 500 * 10) / 1e6) < 1e-12);
  });

  it("returns no price for an unknown model and switches Google's announced rates on their date", () => {
    assert.equal(estimateCostUsd("some-new-model", { input: 1, cachedInput: 0, output: 1 }), undefined);
    assert.equal(rateFor("gemini-4-argon", new Date("2026-11-30T12:00:00Z"))?.input, 2);
    assert.equal(rateFor("gemini-4-argon", new Date("2026-12-01T00:00:00Z"))?.input, 4);
  });

  it("reports counts, reasoning tokens and a labelled cost", () => {
    const r = reportUsage("gpt-6-luna", usage(2000, 0, 800, 600), 1234, new Date("2026-11-14"));
    assert.deepEqual([r.input_tokens, r.cached_input_tokens, r.output_tokens, r.reasoning_tokens, r.model_ms, r.cost_basis], [2000, 0, 800, 600, 1234, "estimated"]);
    assert.ok(Math.abs((r.est_cost_usd ?? 0) - (2000 * 0.1 + 800 * 0.5) / 1e6) < 1e-9);
    assert.equal(reportUsage("some-new-model", usage(1, 0, 1, 0), 1).cost_basis, "no_price");
    assert.equal(reportUsage("gpt-6-luna", undefined, 1).cost_basis, "no_usage");
  });
});

describe("watch and consult log tokens and cost", () => {
  const decision = JSON.stringify({ action: "wait", line: null, reason: "fine", hint_spoken: null, hint_written: null });

  it("watch writes model, tokens, cost and provider time on its one line, and no content", async () => {
    const { models } = fakeModels(decision);
    const r = await reply(await handleWatch(post("/api/watch", watchBody({ problem_id: "u3-01" })), deps(liveEnv(), models)));
    assert.equal(r.status, 200);
    const line = logs.lines.at(-1)!;
    for (const key of ["model", "level", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_tokens", "est_cost_usd", "model_ms", "cost_basis"]) {
      assert.ok(key in line, `log line has ${key}`);
    }
    assert.deepEqual([line.input_tokens, line.output_tokens, line.cached_input_tokens, line.level], [10, 10, 0, "high_school"]);
    assert.equal(line.cost_basis, "estimated");
    assert.ok(!logs.raw.join("\n").includes("fine"), "the model's reason is not logged");
  });

  it("consult writes the same fields", async () => {
    const { models } = fakeModels("Line one is written. Looks unfinished.");
    const body = { session_id: "s", problem_id: "u3-01", image_png_base64: watchBody().image_png_base64, question: "is this right", recent: [] };
    await handleConsult(post("/api/consult", body), deps(liveEnv(), models));
    const line = logs.lines.at(-1)!;
    assert.equal(line.endpoint, "consult");
    assert.deepEqual([line.input_tokens, line.output_tokens, line.cost_basis], [10, 10, "estimated"]);
    assert.ok(!logs.raw.join("\n").includes("Looks unfinished"));
  });
});

describe("difficulty routing", () => {
  it("school problems are high school and college problems advanced; a missing level means high school", () => {
    assert.equal(levelOf(findProblem("u3-01")!), "high_school");
    assert.equal(levelOf(findProblem("c1-01")!), "advanced");
    assert.equal(levelOf({ id: "x", prompt_plain: "", worked_solution: [], final_answer: "" }), "high_school");
    assert.equal(levelOf({ id: "x", prompt_plain: "", worked_solution: [], final_answer: "", level: "advanced" }), "advanced");
  });

  it("advanced reads the _ADVANCED variables and defaults to the frontier model; both levels are overridable", () => {
    const env = {};
    // Defaults chosen by the eval (server/eval/results/main2.md): luna for high school, sol for advanced.
    assert.equal(roleConfig("watch", env).model, "gpt-6-luna");
    assert.equal(roleConfig("ask", env).model, "gpt-6-luna");
    assert.equal(roleConfig("watch", env, "advanced").model, "gpt-6.1-sol");
    assert.equal(roleConfig("ask", env, "advanced").model, "gpt-6.1-sol");
    const over = { WATCH_MODEL: "cheap", WATCH_MODEL_ADVANCED: "big", ASK_MODEL_ADVANCED: "bigger", WATCH_EFFORT: "low" };
    assert.equal(roleConfig("watch", over).model, "cheap");
    assert.equal(roleConfig("watch", over).effort, "low");
    assert.equal(roleConfig("watch", over, "advanced").model, "big");
    assert.equal(roleConfig("watch", over, "advanced").effort, undefined);
    assert.equal(roleConfig("ask", over, "advanced").model, "bigger");
    assert.throws(() => roleConfig("watch", { WATCH_EFFORT: "turbo" }), /WATCH_EFFORT/);
  });

  it("configForLevel gives the advanced model, and a 503 when the advanced provider has no key", () => {
    const ctx = new RequestCtx("watch", "POST");
    const student = { id: "1", planLive: false, capSeconds: 28800, disabled: false, usage: EMPTY_USAGE };
    const opened = {
      ok: true as const,
      scripted: false,
      configs: { watch: roleConfig("watch", {}) },
      keys: { watch: "k" },
      student,
      store: testStore().store,
      code: TOKEN,
      month: TEST_MONTH,
      now: FIXED_NOW,
    };
    const adv = configForLevel(ctx, opened, { OPENAI_API_KEY: "k" }, "watch", "advanced");
    assert.ok(adv.ok && adv.cfg.model === "gpt-6.1-sol" && adv.cfg.level === "advanced");
    const noKey = configForLevel(ctx, opened, { WATCH_PROVIDER_ADVANCED: "google" }, "watch", "advanced");
    assert.ok(!noKey.ok && noKey.response.status === 503);
  });

  it("sends reasoning effort in each provider's own shape, and nothing when unset", () => {
    assert.equal(providerOptionsFor(roleConfig("watch", {})), undefined);
    assert.deepEqual(providerOptionsFor(roleConfig("watch", { WATCH_EFFORT: "low" })), { openai: { reasoningEffort: "low" } });
    assert.deepEqual(providerOptionsFor(roleConfig("watch", { WATCH_PROVIDER: "google", WATCH_EFFORT: "low" })), {
      google: { thinkingConfig: { thinkingLevel: "low" } },
    });
  });

  void TOKEN;
});
