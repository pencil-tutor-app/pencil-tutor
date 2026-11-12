// One structured JSON line per request. Ids, sizes, counts and reason labels only:
// never images, audio, transcripts, hints, tokens or keys.

export type LogFields = Record<string, string | number | boolean | null | undefined>;

let sink: (line: string) => void = (line) => console.log(line);

export function setLogSink(fn: (line: string) => void): () => void {
  const previous = sink;
  sink = fn;
  return () => {
    sink = previous;
  };
}

export function logLine(level: "info" | "warn" | "error", fields: LogFields): void {
  sink(JSON.stringify({ ts: new Date().toISOString(), svc: "pencil-tutor", level, ...fields }));
}
