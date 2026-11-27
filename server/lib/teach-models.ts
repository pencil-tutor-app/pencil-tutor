import { generateText, NoObjectGeneratedError, NoOutputGeneratedError, Output, type LanguageModel } from "ai";
import type { z } from "zod";
import type { RoleConfig } from "./config.js";
import { classifyFailure, providerOptionsFor, type ModelFailure } from "./models.js";
import { reportUsage, type UsageReport } from "./usage.js";

export const TEACH_TIMEOUT_MS = 40_000;

export type StructuredResult<T> =
  | { kind: "object"; value: T; usage: UsageReport }
  // The answer broke a length limit of its schema: nothing is cut, the call has failed (teach_too_long).
  | { kind: "too_long"; usage: UsageReport }
  | { kind: "malformed"; usage: UsageReport };

// One text-only model call whose answer must fit a schema. Used for the lesson, the practice problem, both calls of the check and
// the follow-up. The tokens are reported even when the answer is unusable, because they were spent.
export async function runStructured<S extends z.ZodType>(args: {
  model: LanguageModel;
  cfg: RoleConfig;
  system: string;
  prompt: string;
  schema: S;
}): Promise<StructuredResult<z.infer<S>> | ModelFailure> {
  const startedAt = Date.now();
  try {
    const result = await generateText({
      model: args.model,
      providerOptions: providerOptionsFor(args.cfg),
      system: args.system,
      prompt: args.prompt,
      output: Output.object({ schema: args.schema }),
      abortSignal: AbortSignal.timeout(TEACH_TIMEOUT_MS),
      maxRetries: 1,
    });
    return { kind: "object", value: result.output as z.infer<S>, usage: reportUsage(args.cfg.model, result.usage, Date.now() - startedAt) };
  } catch (err) {
    if (NoObjectGeneratedError.isInstance(err) || NoOutputGeneratedError.isInstance(err)) {
      const usage = reportUsage(args.cfg.model, NoObjectGeneratedError.isInstance(err) ? err.usage : undefined, Date.now() - startedAt);
      const text = NoObjectGeneratedError.isInstance(err) ? err.text : undefined;
      return { kind: overLimit(args.schema, text) ? "too_long" : "malformed", usage };
    }
    return classifyFailure(err);
  }
}

// True when the text is JSON that fits the schema except for a length limit (a string or an array that is too long).
function overLimit(schema: z.ZodType, text: string | undefined): boolean {
  if (!text) return false;
  try {
    const checked = schema.safeParse(JSON.parse(text));
    return !checked.success && checked.error.issues.some((i) => i.code === "too_big");
  } catch {
    return false;
  }
}
