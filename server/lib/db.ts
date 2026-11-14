import { neon } from "@neondatabase/serverless";
import type { Env } from "./config.js";

// The one door to Postgres. Every SQL statement in the server goes through `Db.query`, with raw SQL text and numbered
// placeholders (never string-built values). The database is Neon (Vercel Marketplace, free plan), reached over HTTPS, so a
// Vercel function holds no connection between requests. No ORM, no Supabase client.

export type Row = Record<string, unknown>;

export interface Db {
  query(text: string, params?: unknown[]): Promise<Row[]>;
}

// A database failure as a label only (the driver's message can echo the connection string or a value).
export class DatabaseError extends Error {
  constructor(readonly label: string) {
    super(label);
    this.name = "DatabaseError";
  }
}

const DB_TIMEOUT_MS = 5_000;

// DATABASE_URL is the pooled Neon connection string the Marketplace integration sets. POSTGRES_URL is the same value
// under its older name.
export function databaseUrl(env: Env): string | undefined {
  return env.DATABASE_URL?.trim() || env.POSTGRES_URL?.trim() || undefined;
}

type NeonSql = ReturnType<typeof neon>;
const clients = new Map<string, NeonSql>();

export function openDb(env: Env): Db | undefined {
  const url = databaseUrl(env);
  if (!url) return undefined;
  let sql = clients.get(url);
  if (!sql) {
    sql = neon(url);
    clients.set(url, sql);
  }
  const client = sql;
  return {
    async query(text, params = []) {
      try {
        const rows = await client.query(text, params, { fetchOptions: { signal: AbortSignal.timeout(DB_TIMEOUT_MS) } });
        return rows as Row[];
      } catch (err) {
        throw new DatabaseError(databaseErrorLabel(err));
      }
    },
  };
}

// Postgres errors carry a five character SQLSTATE `code` (for example 42P01 = table missing). Timeouts and network
// failures have none. Only that code or the error name ever becomes the label.
export function databaseErrorLabel(err: unknown): string {
  const code = typeof err === "object" && err !== null && "code" in err ? String((err as { code: unknown }).code) : "";
  if (/^[0-9A-Z]{5}$/.test(code)) return `db_${code.toLowerCase()}`;
  // The Neon driver wraps a failed or aborted fetch in a NeonDbError and keeps the original under `sourceError`.
  const source = typeof err === "object" && err !== null && "sourceError" in err ? (err as { sourceError?: unknown }).sourceError : undefined;
  const name = source instanceof Error ? source.name : err instanceof Error ? err.name : "";
  if (name === "TimeoutError" || name === "AbortError") return "db_timeout";
  return `db_error_${name || "unknown"}`;
}
