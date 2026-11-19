import type { StudentOrigin } from "./free-config.js";
import {
  chargeFor,
  claimFromStamps,
  EMPTY_USAGE,
  DEFAULT_MONTHLY_CAP_SECONDS,
  type ActivityKind,
  type Charge,
  type SlotClaim,
  type SpeechProvider,
  type StudentRecord,
  type StudentStore,
  type Usage,
} from "./students.js";

// An in-memory StudentStore with the same rules as the Postgres one (it uses the same chargeFor and claimFromStamps). Used by the
// unit tests and by local runs without a database. The Postgres statements themselves are checked by test/free.pglite.test.ts
// (PGlite, CI) and test/db.integration.test.ts (the real database, off unless asked for).
type Row = { id: string; code: string; capSeconds: number; planLive: boolean; disabled: boolean; origin: StudentOrigin };

export class MemoryStudentStore implements StudentStore {
  readonly kind = "memory" as const;
  private nextId = 1;
  private readonly students: Row[] = [];
  private readonly usage = new Map<string, Usage & { lowNotice: boolean; usedUpNotice: boolean; looks: number; questions: number; ttsCharsEleven: number }>();
  private readonly freeSpend = new Map<string, { micros: number; elevenChars: number; calls: number }>();
  private readonly slots = new Map<string, { stamps: number[]; updatedAt: number }>();
  failWith: Error | null = null; // set in a test to simulate a database outage
  failCreateWith: Error | null = null; // set in a test to make only the creation of a free code fail

  add(code: string, options: { capSeconds?: number; planLive?: boolean; disabled?: boolean; origin?: StudentOrigin } = {}): string {
    const id = String(this.nextId++);
    this.students.push({
      id,
      code,
      capSeconds: options.capSeconds ?? DEFAULT_MONTHLY_CAP_SECONDS,
      planLive: options.planLive ?? false,
      disabled: options.disabled ?? false,
      origin: options.origin ?? "admin",
    });
    return id;
  }

  // For tests: the students of one origin, and how much of the free month and address table is in use.
  codesOf(origin: StudentOrigin): string[] {
    return this.students.filter((s) => s.origin === origin).map((s) => s.code);
  }
  freeMonth(month: string): { micros: number; elevenChars: number; calls: number } {
    return { ...(this.freeSpend.get(month) ?? { micros: 0, elevenChars: 0, calls: 0 }) };
  }
  slotCount(ipHash: string): number {
    return this.slots.get(ipHash)?.stamps.length ?? 0;
  }
  setFreeSpend(month: string, micros: number): void {
    const row = this.freeSpend.get(month) ?? { micros: 0, elevenChars: 0, calls: 0 };
    row.micros = micros;
    this.freeSpend.set(month, row);
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
      origin: row.origin,
      freeSpentMicros: row.origin === "free" ? (this.freeSpend.get(month)?.micros ?? 0) : null,
      planLive: row.planLive,
      capSeconds: row.capSeconds,
      disabled: row.disabled,
      usage: { ...u, lowNoticed: u.lowNotice, usedUpNoticed: u.usedUpNotice },
    };
  }

  async chargeActivity(studentId: string, month: string, at: Date | null, kind: ActivityKind): Promise<{ usage: Usage; charge: Charge }> {
    this.check();
    const u = this.slot(studentId, month);
    const result = chargeFor(u.lastActivityAt, at);
    u.countedSeconds += result.seconds;
    u.lastActivityAt = result.lastActivityAt;
    if (kind === "look") u.looks += 1;
    if (kind === "question") u.questions += 1;
    return {
      usage: { ...u, lowNoticed: u.lowNotice, usedUpNoticed: u.usedUpNotice },
      charge: { seconds: result.seconds, reason: result.reason, gapSeconds: result.gapSeconds },
    };
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

  async createFreeStudent(code: string, capSeconds: number): Promise<boolean> {
    this.check();
    if (this.failCreateWith) throw this.failCreateWith;
    if (this.students.some((s) => s.code === code)) return false;
    this.add(code, { capSeconds, planLive: false, origin: "free" });
    return true;
  }

  async claimFreeCodeSlot(ipHash: string, at: Date, limit: number): Promise<SlotClaim> {
    this.check();
    const row = this.slots.get(ipHash);
    const { stamps, claim } = claimFromStamps(row?.stamps ?? [], at.getTime(), limit);
    // A refusal writes nothing, exactly like the SQL.
    if (claim.allowed) this.slots.set(ipHash, { stamps, updatedAt: at.getTime() });
    return claim;
  }

  async releaseFreeCodeSlot(ipHash: string, at: Date): Promise<void> {
    this.check();
    const row = this.slots.get(ipHash);
    if (row) row.stamps = row.stamps.filter((t) => t !== at.getTime());
  }

  async purgeStaleFreeCodeSlots(before: Date): Promise<number> {
    this.check();
    let removed = 0;
    for (const [hash, row] of this.slots) {
      if (row.updatedAt < before.getTime()) {
        this.slots.delete(hash);
        removed += 1;
      }
    }
    return removed;
  }

  async freeSpentMicros(month: string): Promise<number> {
    this.check();
    return this.freeSpend.get(month)?.micros ?? 0;
  }

  async reserveFreeSpend(month: string, micros: number, ceilingMicros: number): Promise<number | null> {
    this.check();
    const row = this.freeSpend.get(month) ?? { micros: 0, elevenChars: 0, calls: 0 };
    if (row.micros + micros > ceilingMicros) return null;
    row.micros += micros;
    row.calls += 1;
    this.freeSpend.set(month, row);
    return row.micros;
  }

  async settleFreeSpend(month: string, deltaMicros: number, elevenChars: number): Promise<number> {
    this.check();
    const row = this.freeSpend.get(month) ?? { micros: 0, elevenChars: 0, calls: 0 };
    row.micros = Math.max(0, row.micros + deltaMicros);
    row.elevenChars += elevenChars;
    this.freeSpend.set(month, row);
    return row.micros;
  }
}
