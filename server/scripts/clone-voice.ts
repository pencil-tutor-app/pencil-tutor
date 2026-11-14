import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";

// Makes the tutor's voice: an ElevenLabs Instant Voice Clone named "Edward Tutor" from one local recording, and prints ONLY the new
// voice id on stdout (errors go to stderr). Edward runs it once the recording exists:
//
//   scripts/clone-voice /path/to/recording.m4a
//
// Then point the server at the clone (no code change): set ELEVENLABS_VOICE_ID to the printed id in Vercel (production) and redeploy.
// How it signs in: with ELEVENLABS_API_KEY in the environment it calls the API directly; otherwise it uses the signed-in `elevenlabs`
// command line tool (the sign-in that already exists on this Mac). Recording advice (ElevenLabs): clean, one speaking style, no
// background noise, because Eleven v4 copies the recording faithfully, flaws included
// (https://elevenlabs.io/docs/overview/capabilities/text-to-speech/eleven-v4).

export const VOICE_NAME = "Edward Tutor";
const ADD_VOICE_URL = "https://api.elevenlabs.io/v1/voices/add";
const MAX_FILE_BYTES = 50 * 1024 * 1024;

// The new voice's id from the API or CLI JSON reply, or null when the reply has none.
export function parseVoiceId(reply: string): string | null {
  try {
    const parsed = JSON.parse(reply) as { voice_id?: unknown };
    return typeof parsed.voice_id === "string" && /^[A-Za-z0-9]{10,40}$/.test(parsed.voice_id) ? parsed.voice_id : null;
  } catch {
    return null;
  }
}

export type PathCheck = { ok: true } | { ok: false; reason: string };

export function checkRecording(path: string | undefined): PathCheck {
  if (!path) return { ok: false, reason: "give the path of the recording: scripts/clone-voice /path/to/recording.m4a" };
  if (!existsSync(path)) return { ok: false, reason: "that file does not exist" };
  const size = statSync(path).size;
  if (size === 0) return { ok: false, reason: "that file is empty" };
  if (size > MAX_FILE_BYTES) return { ok: false, reason: "that file is over 50 MB; use a shorter recording" };
  return { ok: true };
}

async function viaApi(path: string, apiKey: string): Promise<string> {
  const form = new FormData();
  form.set("name", VOICE_NAME);
  form.set("description", "The tutor's voice (instant voice clone).");
  // Home recordings carry room noise; ElevenLabs strips it before cloning so the clone does not copy the hiss.
  form.set("remove_background_noise", "true");
  form.append("files", new Blob([readFileSync(path)]), basename(path));
  const response = await fetch(ADD_VOICE_URL, { method: "POST", headers: { "xi-api-key": apiKey }, body: form });
  const text = await response.text();
  if (!response.ok) throw new Error(`ElevenLabs refused the clone (HTTP ${response.status})`);
  const id = parseVoiceId(text);
  if (!id) throw new Error("ElevenLabs answered without a voice id");
  return id;
}

function viaCli(path: string): string {
  const run = spawnSync("elevenlabs", ["voices", "ivc", "create", "--name", VOICE_NAME, "--files", path, "--format", "json"], { encoding: "utf8" });
  if (run.error) throw new Error("the elevenlabs command line tool is not installed and ELEVENLABS_API_KEY is not set");
  if (run.status !== 0) throw new Error(`the elevenlabs tool failed (exit ${run.status})`);
  const id = parseVoiceId(run.stdout);
  if (!id) throw new Error("the elevenlabs tool answered without a voice id");
  return id;
}

async function main(argv: string[]): Promise<number> {
  const path = argv[0];
  const check = checkRecording(path);
  if (!check.ok) {
    console.error(check.reason);
    return 2;
  }
  try {
    const apiKey = process.env.ELEVENLABS_API_KEY?.trim();
    const id = apiKey ? await viaApi(path!, apiKey) : viaCli(path!);
    console.log(id);
    return 0;
  } catch (err) {
    console.error(err instanceof Error ? err.message : "the clone failed");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((code) => process.exit(code));
}
