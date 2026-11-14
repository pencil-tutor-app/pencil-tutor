import {
  chargeFor,
  EMPTY_USAGE,
  DEFAULT_MONTHLY_CAP_SECONDS,
  type ActivityKind,
  type SpeechProvider,
  type StudentRecord,
  type StudentStore,
  type Usage,
} from "./students.js";

// An in-memory StudentStore with the same rules as the Postgres one (it uses the same chargeFor). Used by the unit tests and
// by local runs without a database. The Postgres statements themselves are checked by test/db.integration.test.ts.
type Row = { id: string; code: string; capSeconds: number; planLive: boolean; disabled: boolean };

export class MemoryStudentStore implements StudentStore {
  readonly kind = "memory" as const;
  private nextId = 1;
  private readonly students: Row[] = [];
  private readonly usage = new Map<string, Usage & { lowNotice: boolean; usedUpNotice: boolean; looks: number; questions: number; ttsCharsEleven: number }>();
  failWith: Error | null = null; // set in a test to simulate a database outage

  add(code: string, options: { capSeconds?: number; planLive?: boolean; disabled?: boolean } = {}): string {
    const id = String(this.nextId++);
    this.students.push({
      id,
      code,
      capSeconds: options.capSeconds ?? DEFAULT_MONTHLY_CAP_SECONDS,
      planLive: options.planLive ?? false,
      disabled: options.disabled ?? false,
    });
    return id;
  }

  setUsage(studentId: string, month: string, patch: Partial<Usage>): void {
    this.slot(studentId, month);
    const key = `${studentId}|${month}`;
    Object.assign(this.usage.get(key)!, patch);
  }

  usageOf(studentId: string, month: string): Usage & { looks: number; questions: number; ttsCharsEleven: number } {
    return this.slot(studentId, month);
  }

  private slot(studentId: string, month: string) {
    const key = `${studentId}|${month}`;
    let u = this.usage.get(key);
    if (!u) {
      u = { ...EMPTY_USAGE, lowNotice: false, usedUpNotice: false, looks: 0, questions: 0, ttsCharsEleven: 0 };
      this.usage.set(key, u);
    }
    return u;
  }

  private check(): void {
    if (this.failWith) throw this.failWith;
  }

  async lookup(code: string, month: string): Promise<StudentRecord | null> {
    this.check();
    const row = this.students.find((s) => s.code === code);
    if (!row) return null;
    const u = this.slot(row.id, month);
    return {
      id: row.id,
      planLive: row.planLive,
      capSeconds: row.capSeconds,
      disabled: row.disabled,
      usage: { ...u, lowNoticed: u.lowNotice, usedUpNoticed: u.usedUpNotice },
    };
  }

  async chargeActivity(studentId: string, month: string, at: Date, kind: ActivityKind): Promise<Usage> {
    this.check();
    const u = this.slot(studentId, month);
    const charge = chargeFor(u.coveredUntil, at);
    u.countedSeconds += charge.addedSeconds;
    u.coveredUntil = charge.coveredUntil;
    if (kind === "look") u.looks += 1;
    if (kind === "question") u.questions += 1;
    return { ...u, lowNoticed: u.lowNotice, usedUpNoticed: u.usedUpNotice };
  }

  async addSpeech(studentId: string, month: string, chars: number, provider: SpeechProvider): Promise<number> {
    this.check();
    const u = this.slot(studentId, month);
    u.ttsChars += chars;
    if (provider === "elevenlabs") u.ttsCharsEleven += chars;
    return u.ttsChars;
  }

  async claimNotice(studentId: string, month: string, which: "low" | "used_up"): Promise<boolean> {
    this.check();
    const u = this.slot(studentId, month);
    if (which === "low") {
      if (u.lowNotice) return false;
      u.lowNotice = true;
    } else {
      if (u.usedUpNotice) return false;
      u.usedUpNotice = true;
    }
    return true;
  }
}
