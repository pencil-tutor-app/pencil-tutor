import { openDb } from "../lib/db.js";
import { StudentAdmin } from "../lib/students-admin.js";

// A live check of the deployed server, with receipts. It makes two throwaway codes (one with a normal cap, one with a tiny cap),
// drives the deployed endpoints, prints what happened, and deletes both codes at the end. It prints codes only as the short log hash.
// Run through scripts/live-check, which loads the production database address exec-only:  scripts/live-check [base-url]
// Needs no ElevenLabs or OpenAI key of its own: it only talks to the deployed server and the database.

const BASE = (process.argv[2] ?? "https://pencil-tutor.vercel.app").replace(/\/$/, "");
const SENTENCE = "Take another look at line two. What did you do to both sides of the equation?";

const ms = (from: number) => Math.round(performance.now() - from);
const out: string[] = [];
const say = (line: string) => {
  out.push(line);
  console.log(line);
};

async function call(path: string, code: string | null, init: { method?: string; body?: unknown } = {}) {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (code) headers.authorization = `Bearer ${code}`;
  const response = await fetch(`${BASE}${path}`, {
    method: init.method ?? (init.body === undefined ? "GET" : "POST"),
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const text = await response.text();
  let json: Record<string, unknown> = {};
  try {
    json = JSON.parse(text) as Record<string, unknown>;
  } catch {
    // not JSON
  }
  return { status: response.status, json };
}

// One speak call, timed: headers, first audio byte, whole body.
async function timedSpeak(code: string, body: unknown) {
  const started = performance.now();
  const response = await fetch(`${BASE}/api/speak`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${code}` },
    body: JSON.stringify(body),
  });
  const headersAt = ms(started);
  if (!response.ok || !response.body) {
    const text = await response.text();
    return { status: response.status, error: text.slice(0, 160), headersAt };
  }
  const reader = response.body.getReader();
  let bytes = 0;
  let firstAudioAt = -1;
  for (;;) {
    const next = await reader.read();
    if (next.done) break;
    if (firstAudioAt < 0) firstAudioAt = ms(started);
    bytes += next.value.length;
  }
  return {
    status: response.status,
    headersAt,
    firstAudioAt,
    totalAt: ms(started),
    bytes,
    audioSeconds: Math.round((bytes / 48_000) * 100) / 100,
    provider: response.headers.get("x-voice-provider"),
    fallback: response.headers.get("x-voice-fallback"),
    format: response.headers.get("x-audio-format"),
    serverMs: response.headers.get("x-latency-ms"),
    allowanceState: response.headers.get("x-allowance-state"),
  };
}

async function main(): Promise<void> {
  const db = openDb(process.env);
  if (!db) throw new Error("DATABASE_URL is not set; run this through scripts/live-check");
  const admin = new StudentAdmin(db);
  const made: string[] = [];
  try {
    const health = await call("/api/health", null);
    say(`health ${health.status}: voice_provider=${String(health.json.voice_provider)} database_configured=${String(health.json.database_configured)}`);
    const voice = health.json.voice as { elevenlabs?: { key_present?: boolean; model?: string; voice_id?: string; output_format?: string } } | undefined;
    say(`  elevenlabs key_present=${String(voice?.elevenlabs?.key_present)} model=${String(voice?.elevenlabs?.model)} voice_id=${String(voice?.elevenlabs?.voice_id)} output=${String(voice?.elevenlabs?.output_format)}`);

    const normal = await admin.create({});
    made.push(normal.code);
    const tiny = await admin.create({ capSeconds: 60 });
    made.push(tiny.code);
    say(`made two throwaway codes: normal (log id ${normal.hash}), tiny 1-minute cap (log id ${tiny.hash})`);

    const unknown = await call("/api/me", "ZZZZZZZZ");
    say(`unknown code -> ${unknown.status} ${String(unknown.json.error)} (${String(unknown.json.reason)})`);
    const malformed = await call("/api/me", "not-a-code");
    say(`malformed code -> ${malformed.status} ${String(malformed.json.error)} (${String(malformed.json.reason)})`);

    const firstMe = performance.now();
    const me = await call("/api/me", normal.code);
    const a = me.json.allowance as Record<string, unknown>;
    say(`valid code /api/me -> ${me.status} in ${ms(firstMe)} ms: plan.live=${String((me.json.plan as { live?: boolean })?.live)} month=${String(a?.month)} left=${String(a?.remaining_minutes)} min state=${String(a?.state)}`);
    const secondMe = performance.now();
    await call("/api/me", normal.code);
    say(`  second /api/me (warm) in ${ms(secondMe)} ms`);

    for (let i = 1; i <= 3; i += 1) {
      const r = await timedSpeak(normal.code, { session_id: "live-check", text: SENTENCE, purpose: "hint" });
      say(`speak #${i}: ${JSON.stringify(r)}`);
    }

    const beat = await call("/api/heartbeat", normal.code, { body: { session_id: "live-check", problem_id: "u3-04" } });
    const ba = beat.json.allowance as Record<string, unknown>;
    say(`heartbeat -> ${beat.status}: used=${String(ba?.used_seconds)} s left=${String(ba?.remaining_minutes)} min`);

    say("--- tiny cap (60 s) ---");
    const first = await call("/api/heartbeat", tiny.code, { body: { problem_id: "u3-04" } });
    const fa = first.json.allowance as Record<string, unknown>;
    say(`first activity -> ${first.status}: used=${String(fa?.used_seconds)} s of ${String(fa?.cap_seconds)} s state=${String(fa?.state)} notice=${String(fa?.notice)}`);
    const second = await call("/api/heartbeat", tiny.code, { body: { problem_id: "u3-04" } });
    say(`next request -> ${second.status} ${String(second.json.error)} (${String(second.json.reason)})`);
    const refusedSpeak = await timedSpeak(tiny.code, { text: SENTENCE, purpose: "hint" });
    say(`normal speech when used up -> ${refusedSpeak.status} ${String((refusedSpeak as { error?: string }).error ?? "")}`);
    const notice = await timedSpeak(tiny.code, { purpose: "allowance_used_up" });
    say(`used-up announcement (server-written) -> ${JSON.stringify(notice)}`);
    const meUsed = await call("/api/me", tiny.code);
    say(`/api/me still answers when used up -> ${meUsed.status} state=${String((meUsed.json.allowance as { state?: string })?.state)}`);
    const live = await call("/api/live-session", normal.code, { body: { session_id: "x", problem_id: "u3-04", sdp: "v=0\r\n" } });
    say(`live voice on a plan without it -> ${live.status} ${String(live.json.error)}`);
  } finally {
    for (const code of made) await admin.remove(code);
    say(`cleaned up: deleted ${made.length} throwaway code(s)`);
  }
}

main().then(
  () => process.exit(0),
  (err: unknown) => {
    console.error(`live check failed: ${err instanceof Error ? ((err as { label?: string }).label ?? err.message) : "unknown error"}`);
    process.exit(1);
  },
);
