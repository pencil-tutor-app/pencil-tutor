import type { VerifiedTransaction } from "./app-store.js";
import type { Subscriber, SubscriptionStore } from "./subscriptions.js";
import {
  chargeFor,
  EMPTY_USAGE,
  generateCode,
  DEFAULT_MONTHLY_CAP_SECONDS,
  type ActivityKind,
  type Charge,
  type SpeechProvider,
  type StudentRecord,
  type StudentStore,
  type Usage,
} from "./students.js";

// An in-memory StudentStore with the same rules as the Postgres one (it uses the same chargeFor). Used by the unit tests and
// by local runs without a database. The Postgres statements themselves are checked by test/db.integration.test.ts.
type Row = {
  id: string;
  code: string;
  capSeconds: number;
  planLive: boolean;
  disabled: boolean;
  originalTransactionId?: string; // set for a student that came from the in-app subscription
  accessUntil?: Date;
};
type LedgerRow = { tx: VerifiedTransaction; studentId: string; toppedUp: boolean };

export class MemoryStudentStore implements StudentStore, SubscriptionStore {
  readonly kind = "memory" as const;
  private nextId = 1;
  private readonly students: Row[] = [];
  private readonly ledger = new Map<string, LedgerRow>();
  clock: () => Date = () => new Date(); // what "now" means for a subscription's end; tests set it
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
    const subscriptionEnded = row.originalTransactionId !== undefined && (row.accessUntil ?? new Date(0)).getTime() <= this.clock().getTime();
    return {
      id: row.id,
      planLive: row.planLive,
      capSeconds: row.capSeconds,
      disabled: row.disabled || subscriptionEnded,
      subscriptionEnded,
      usage: { ...u, lowNoticed: u.lowNotice, usedUpNoticed: u.usedUpNotice },
    };
  }

  // ----- The in-app subscription (same rules as PgSubscriptionStore) -----

  async findStudent(originalTransactionId: string): Promise<Subscriber | null> {
    this.check();
    const row = this.students.find((s) => s.originalTransactionId === originalTransactionId);
    return row ? { id: row.id, code: row.code } : null;
  }

  async claimStudent(originalTransactionId: string, capSeconds: number): Promise<Subscriber & { created: boolean }> {
    this.check();
    // No await between the check and the insert: like the unique index in Postgres, this makes two callers get one student.
    const existing = this.students.find((s) => s.originalTransactionId === originalTransactionId);
    if (existing) return { id: existing.id, code: existing.code, created: false };
    let code = generateCode();
    while (this.students.some((s) => s.code === code)) code = generateCode();
    const id = this.add(code, { capSeconds });
    const row = this.students.find((s) => s.id === id)!;
    row.originalTransactionId = originalTransactionId;
    return { id, code, created: true };
  }

  async recordTransaction(tx: VerifiedTransaction, studentId: string, toppedUp: boolean): Promise<{ toppedUp: boolean }> {
    this.check();
    const known = this.ledger.get(tx.transactionId);
    if (!known) {
      this.ledger.set(tx.transactionId, { tx, studentId, toppedUp });
      return { toppedUp };
    }
    if (tx.signedAt.getTime() > known.tx.signedAt.getTime()) known.tx = tx;
    return { toppedUp: known.toppedUp };
  }

  async settleAccess(originalTransactionId: string): Promise<Date> {
    this.check();
    const live = [...this.ledger.values()].filter((l) => l.tx.originalTransactionId === originalTransactionId && !l.tx.revokedAt);
    const until = new Date(live.reduce((latest, l) => Math.max(latest, l.tx.expiresAt.getTime()), 0));
    const row = this.students.find((s) => s.originalTransactionId === originalTransactionId);
    if (row) row.accessUntil = until;
    return until;
  }

  async topUpMonth(studentId: string, month: string): Promise<{ countedSeconds: number; bonusSeconds: number } | null> {
    this.check();
    if (!this.usage.has(`${studentId}|${month}`)) return null;
    const u = this.slot(studentId, month);
    const cap = this.students.find((s) => s.id === studentId)?.capSeconds ?? DEFAULT_MONTHLY_CAP_SECONDS;
    u.bonusSeconds = Math.max(u.bonusSeconds, u.countedSeconds);
    u.usedUpNotice = false;
    if (u.countedSeconds < 0.8 * (cap + u.bonusSeconds)) u.lowNotice = false;
    return { countedSeconds: u.countedSeconds, bonusSeconds: u.bonusSeconds };
  }

  async markToppedUp(transactionId: string): Promise<void> {
    this.check();
    const known = this.ledger.get(transactionId);
    if (known) known.toppedUp = true;
  }

  // For tests: the ledger and the student's end-of-access time.
  ledgerOf(transactionId: string): LedgerRow | undefined {
    return this.ledger.get(transactionId);
  }
  studentByCode(code: string): Row | undefined {
    return this.students.find((s) => s.code === code);
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
}
