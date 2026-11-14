// Price table for the text models the watch, ask and consult roles can run on. Used only to ESTIMATE cost in the log;
// the provider's invoice is the truth. US dollars per 1,000,000 tokens, standard (not batch, not fast) tier.
//
// Sources, fetched 2026-11-14:
//   OpenAI   https://developers.openai.com/api/docs/pricing  (standard tier table: Input, Cached input, Output)
//   Google   https://ai.google.dev/gemini-api/docs/pricing   (Gemini 4 Argon and Gemini 3.8 Flash, Standard, paid tier;
//            output price includes thinking tokens; Google has announced the later prices below)
// Update this table when a vendor page changes; an unknown model logs `cost_basis: "no_price"` and no dollar figure.

export type Rate = { input: number; cachedInput: number; output: number };
type Dated = { from: string; rate: Rate }; // `from` is an ISO date (UTC); the latest entry not after "now" applies

const flat = (input: number, cachedInput: number, output: number): Dated[] => [{ from: "2026-01-01", rate: { input, cachedInput, output } }];

export const PRICES: Record<string, Dated[]> = {
  "gpt-6-astra": flat(10, 1, 50),
  "gpt-6.1-sol": flat(2, 0.1, 10),
  "gpt-6.1-terra": flat(1, 0.05, 5),
  "gpt-6-luna": flat(0.1, 0.01, 0.5),
  "gemini-4-argon": [
    { from: "2026-01-01", rate: { input: 2, cachedInput: 0.1, output: 10 } },
    { from: "2026-12-01", rate: { input: 4, cachedInput: 0.2, output: 20 } },
  ],
  "gemini-3.8-flash": [
    { from: "2026-01-01", rate: { input: 0.75, cachedInput: 0.075, output: 3.75 } },
    { from: "2027-01-01", rate: { input: 1.5, cachedInput: 0.15, output: 7.5 } },
  ],
};

export function rateFor(model: string, at: Date = new Date()): Rate | undefined {
  const schedule = PRICES[model];
  if (!schedule) return undefined;
  const day = at.toISOString().slice(0, 10);
  let current: Rate | undefined;
  for (const entry of schedule) if (entry.from <= day) current = entry.rate;
  return current;
}

export type TokenCounts = { input: number; cachedInput: number; output: number };

// Cached input is billed at the cached rate, the rest of the input at the input rate. `output` already includes
// reasoning (thinking) tokens for both providers. Returns undefined for a model with no price.
export function estimateCostUsd(model: string, tokens: TokenCounts, at: Date = new Date()): number | undefined {
  const rate = rateFor(model, at);
  if (!rate) return undefined;
  const cached = Math.min(tokens.cachedInput, tokens.input);
  const fresh = tokens.input - cached;
  return (fresh * rate.input + cached * rate.cachedInput + tokens.output * rate.output) / 1_000_000;
}
