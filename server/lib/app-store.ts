import { createHash } from "node:crypto";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import type { Env } from "./config.js";
import { appleRootCertificates } from "./apple-root.js";

// The one place the server talks to Apple's signed data. Everything account-dependent comes from the environment, so the same code
// runs under Edward's personal developer account or a company one (docs/app-store.md has the values and where to find them):
//   APPLE_IAP_PRODUCT_ID     the subscription's product id in App Store Connect (the app's Info.plist IAP_PRODUCT_ID must match)
//   APPLE_BUNDLE_ID          the app's bundle id
//   APPLE_APP_APPLE_ID       the app's numeric Apple id (App Store Connect > App Information); needed only for "production"
//   APPLE_IAP_ENVIRONMENTS   comma list of "sandbox" and/or "production" (default "sandbox": nothing real is accepted until set)
//   APPLE_ONLINE_CHECKS      "0" turns off Apple's certificate revocation check (default on)
//   IAP_MONTHLY_MINUTES      minutes a subscriber gets each month (default 480 = 8 hours)

export type AppStoreEnvironment = "production" | "sandbox";
export const DEFAULT_IAP_MONTHLY_MINUTES = 480;

export type AppStoreConfig = {
  productId: string;
  bundleId: string;
  appAppleId: number | undefined;
  environments: AppStoreEnvironment[];
  onlineChecks: boolean;
  monthlySeconds: number;
};
export type AppStoreConfigResult = { ok: true; config: AppStoreConfig } | { ok: false; reason: string };

// Reads the settings. A missing or bad setting is a reason label that names the variable (never its value).
export function appStoreConfig(env: Env): AppStoreConfigResult {
  const productId = env.APPLE_IAP_PRODUCT_ID?.trim();
  if (!productId) return { ok: false, reason: "APPLE_IAP_PRODUCT_ID is not set" };
  const bundleId = env.APPLE_BUNDLE_ID?.trim();
  if (!bundleId) return { ok: false, reason: "APPLE_BUNDLE_ID is not set" };

  const listed = (env.APPLE_IAP_ENVIRONMENTS ?? "sandbox").split(",").map((v) => v.trim().toLowerCase()).filter(Boolean);
  const environments: AppStoreEnvironment[] = [];
  for (const name of listed) {
    if (name !== "production" && name !== "sandbox") return { ok: false, reason: 'APPLE_IAP_ENVIRONMENTS must list "sandbox" and/or "production"' };
    if (!environments.includes(name)) environments.push(name);
  }
  if (environments.length === 0) return { ok: false, reason: "APPLE_IAP_ENVIRONMENTS is empty" };

  let appAppleId: number | undefined;
  const rawAppleId = env.APPLE_APP_APPLE_ID?.trim();
  if (rawAppleId) {
    if (!/^[0-9]{1,15}$/.test(rawAppleId)) return { ok: false, reason: "APPLE_APP_APPLE_ID must be a number" };
    appAppleId = Number(rawAppleId);
  }
  if (environments.includes("production") && appAppleId === undefined) return { ok: false, reason: "APPLE_APP_APPLE_ID is not set (needed for production)" };

  const rawMinutes = env.IAP_MONTHLY_MINUTES?.trim();
  const minutes = rawMinutes ? Number(rawMinutes) : DEFAULT_IAP_MONTHLY_MINUTES;
  if (!Number.isInteger(minutes) || minutes < 1 || minutes > 100_000) return { ok: false, reason: "IAP_MONTHLY_MINUTES must be a whole number of minutes" };

  return { ok: true, config: { productId, bundleId, appAppleId, environments, onlineChecks: env.APPLE_ONLINE_CHECKS?.trim() !== "0", monthlySeconds: minutes * 60 } };
}

// An Apple id is an identifier, so logs carry only this short salted hash of it (8 hex characters).
export const idHash = (value: string): string => createHash("sha256").update(`pencil-tutor:apple:${value}`).digest("hex").slice(0, 8);

// ----- What the rest of the server sees -----

export type VerifiedTransaction = {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  environment: AppStoreEnvironment;
  purchasedAt: Date | null;
  expiresAt: Date;
  revokedAt: Date | null; // set when Apple refunded or revoked this transaction
  signedAt: Date; // when Apple signed this copy; a newer copy of the same transaction wins
};

export type VerifiedNotification = {
  type: string;
  subtype: string | null;
  uuid: string;
  environment: AppStoreEnvironment;
  transaction: VerifiedTransaction | null;
};

// Why a signed payload was refused, as a label for the log and the reply. "unavailable" means Apple's checks could not run (try again).
export type VerifyFailure = {
  ok: false;
  kind: "invalid" | "wrong_app" | "environment_not_accepted" | "wrong_product" | "unavailable";
  label: string;
};
export type Verified<T> = { ok: true; value: T } | VerifyFailure;

// Both methods are given the raw signed string from the phone or from Apple. Tests pass a fake.
export interface AppStoreGateway {
  verifyTransaction(signedTransaction: string): Promise<Verified<VerifiedTransaction>>;
  verifyNotification(signedPayload: string): Promise<Verified<VerifiedNotification>>;
}

// ----- Turning Apple's decoded data into ours -----

const asEnvironment = (value: unknown): AppStoreEnvironment | null => (value === "Production" ? "production" : value === "Sandbox" ? "sandbox" : null);

type DecodedTransactionLike = {
  transactionId?: string;
  originalTransactionId?: string;
  productId?: string;
  bundleId?: string;
  type?: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  signedDate?: number;
  environment?: string;
};

export function toVerifiedTransaction(decoded: DecodedTransactionLike, config: AppStoreConfig): Verified<VerifiedTransaction> {
  const environment = asEnvironment(decoded.environment);
  if (!decoded.transactionId || !decoded.originalTransactionId || !decoded.productId || !environment) {
    return { ok: false, kind: "invalid", label: "transaction_incomplete" };
  }
  if (decoded.bundleId !== config.bundleId) return { ok: false, kind: "wrong_app", label: "bundle_id_mismatch" };
  if (decoded.productId !== config.productId) return { ok: false, kind: "wrong_product", label: "product_not_ours" };
  if (decoded.type !== "Auto-Renewable Subscription") return { ok: false, kind: "wrong_product", label: "not_a_subscription" };
  if (typeof decoded.expiresDate !== "number" || typeof decoded.signedDate !== "number") return { ok: false, kind: "invalid", label: "transaction_incomplete" };
  return {
    ok: true,
    value: {
      transactionId: decoded.transactionId,
      originalTransactionId: decoded.originalTransactionId,
      productId: decoded.productId,
      environment,
      purchasedAt: typeof decoded.purchaseDate === "number" ? new Date(decoded.purchaseDate) : null,
      expiresAt: new Date(decoded.expiresDate),
      revokedAt: typeof decoded.revocationDate === "number" ? new Date(decoded.revocationDate) : null,
      signedAt: new Date(decoded.signedDate),
    },
  };
}

// The environment named inside a signed payload, read WITHOUT trusting it. It only chooses which verifier to ask; that verifier then
// checks the signature, the app and the environment for real, so a lie here can only make verification fail.
export function peekEnvironment(signed: string): AppStoreEnvironment | null {
  const part = signed.split(".")[1];
  if (!part) return null;
  try {
    const body = JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as { environment?: unknown; data?: { environment?: unknown }; summary?: { environment?: unknown } };
    return asEnvironment(body.environment ?? body.data?.environment ?? body.summary?.environment);
  } catch {
    return null;
  }
}

function failureFrom(err: unknown): VerifyFailure {
  if (err instanceof VerificationException) {
    switch (err.status) {
      case VerificationStatus.RETRYABLE_VERIFICATION_FAILURE:
        return { ok: false, kind: "unavailable", label: "apple_check_unavailable" };
      case VerificationStatus.INVALID_APP_IDENTIFIER:
        return { ok: false, kind: "wrong_app", label: "app_identifier_mismatch" };
      case VerificationStatus.INVALID_ENVIRONMENT:
        return { ok: false, kind: "environment_not_accepted", label: "environment_mismatch" };
      case VerificationStatus.VERIFICATION_FAILURE:
        return { ok: false, kind: "invalid", label: "signature_invalid" };
      case VerificationStatus.INVALID_CHAIN_LENGTH:
      case VerificationStatus.INVALID_CERTIFICATE:
        return { ok: false, kind: "invalid", label: "certificate_invalid" };
      default:
        return { ok: false, kind: "invalid", label: "not_a_valid_apple_payload" };
    }
  }
  return { ok: false, kind: "unavailable", label: "verifier_error" };
}

// ----- The real gateway (Apple's official library) -----

const LIBRARY_ENVIRONMENT = { production: Environment.PRODUCTION, sandbox: Environment.SANDBOX } as const;

export function createAppStoreGateway(config: AppStoreConfig): AppStoreGateway {
  const verifiers = new Map<AppStoreEnvironment, SignedDataVerifier>();
  for (const name of config.environments) {
    verifiers.set(name, new SignedDataVerifier(appleRootCertificates(), config.onlineChecks, LIBRARY_ENVIRONMENT[name], config.bundleId, config.appAppleId));
  }
  const pick = (signed: string): { ok: true; verifier: SignedDataVerifier } | VerifyFailure => {
    const named = peekEnvironment(signed);
    if (!named) return { ok: false, kind: "invalid", label: "not_a_valid_apple_payload" };
    const verifier = verifiers.get(named);
    return verifier ? { ok: true, verifier } : { ok: false, kind: "environment_not_accepted", label: `${named}_not_accepted` };
  };

  return {
    async verifyTransaction(signedTransaction) {
      const chosen = pick(signedTransaction);
      if (!chosen.ok) return chosen;
      try {
        return toVerifiedTransaction(await chosen.verifier.verifyAndDecodeTransaction(signedTransaction), config);
      } catch (err) {
        return failureFrom(err);
      }
    },

    async verifyNotification(signedPayload) {
      const chosen = pick(signedPayload);
      if (!chosen.ok) return chosen;
      try {
        const decoded = await chosen.verifier.verifyAndDecodeNotification(signedPayload);
        const environment = asEnvironment(decoded.data?.environment ?? decoded.summary?.environment);
        if (!decoded.notificationType || !decoded.notificationUUID || !environment) return { ok: false, kind: "invalid", label: "notification_incomplete" };
        let transaction: VerifiedTransaction | null = null;
        const inner = decoded.data?.signedTransactionInfo;
        if (inner) {
          const checked = toVerifiedTransaction(await chosen.verifier.verifyAndDecodeTransaction(inner), config);
          // A notification about a product that is not ours (another subscription in the same app) is acknowledged and ignored.
          if (!checked.ok && checked.kind !== "wrong_product") return checked;
          if (checked.ok) transaction = checked.value;
        }
        return { ok: true, value: { type: String(decoded.notificationType), subtype: decoded.subtype ? String(decoded.subtype) : null, uuid: decoded.notificationUUID, environment, transaction } };
      } catch (err) {
        return failureFrom(err);
      }
    },
  };
}
