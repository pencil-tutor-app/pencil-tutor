import type { LanguageModelUsage } from "ai";
import type { LogFields } from "./log.js";
import { estimateCostUsd } from "./pricing.js";

// What one model call cost, as counts only (never text or image content).
export type UsageReport = {
  model_ms: number; // time spent inside the provider call
  input_tokens: number | null;
  cached_input_tokens: number | null;
  output_tokens: number | null;
  reasoning_tokens: number | null; // null when the provider does not report it
  est_cost_usd: number | null;
  cost_basis: "estimated" | "no_price" | "no_usage";
};

export function reportUsage(model: string, usage: LanguageModelUsage | undefined, modelMs: number, at: Date = new Date()): UsageReport {
  const input = usage?.inputTokens;
  const output = usage?.outputTokens;
  const cached = usage?.inputTokenDetails?.cacheReadTokens;
  const reasoning = usage?.outputTokenDetails?.reasoningTokens;
  const base = {
    model_ms: modelMs,
    input_tokens: input ?? null,
    cached_input_tokens: cached ?? null,
    output_tokens: output ?? null,
    reasoning_tokens: reasoning ?? null,
  };
  if (input === undefined || output === undefined) return { ...base, est_cost_usd: null, cost_basis: "no_usage" };
  const cost = estimateCostUsd(model, { input, cachedInput: cached ?? 0, output }, at);
  if (cost === undefined) return { ...base, est_cost_usd: null, cost_basis: "no_price" };
  return { ...base, est_cost_usd: Math.round(cost * 1e7) / 1e7, cost_basis: "estimated" };
}

export const usageFields = (r: UsageReport | undefined): LogFields => (r ? { ...r } : {});
