import assert from "node:assert/strict";
import { createHash, X509Certificate } from "node:crypto";
import { describe, it } from "node:test";
import { APPLE_ROOT_CA_G3_FINGERPRINT_SHA256, appleRootCertificates } from "../lib/apple-root.js";
import { appStoreConfig, createAppStoreGateway, idHash, peekEnvironment, toVerifiedTransaction, type AppStoreConfig } from "../lib/app-store.js";

const GOOD_ENV = { APPLE_IAP_PRODUCT_ID: "penciltutor.monthly", APPLE_BUNDLE_ID: "com.example.penciltutor" };

describe("Apple root certificate", () => {
  it("is Apple Root CA - G3 with the fingerprint Apple publishes", () => {
    const [der] = appleRootCertificates();
    assert.ok(der);
    assert.equal(createHash("sha256").update(der).digest("hex"), APPLE_ROOT_CA_G3_FINGERPRINT_SHA256);
    const cert = new X509Certificate(der);
    assert.match(cert.subject, /CN=Apple Root CA - G3/);
    assert.match(cert.subject, /O=Apple Inc\./);
    assert.ok(new Date(cert.validTo).getFullYear() >= 2039, "valid to 2039");
  });
});

describe("appStoreConfig", () => {
  it("needs a product id and a bundle id, and names the missing one", () => {
    assert.deepEqual(appStoreConfig({}), { ok: false, reason: "APPLE_IAP_PRODUCT_ID is not set" });
    assert.deepEqual(appStoreConfig({ APPLE_IAP_PRODUCT_ID: "x" }), { ok: false, reason: "APPLE_BUNDLE_ID is not set" });
  });

  it("defaults to sandbox only, 480 minutes and online checks on", () => {
    const r = appStoreConfig(GOOD_ENV);
    assert.ok(r.ok);
    assert.deepEqual(r.config, {
      productId: "penciltutor.monthly",
      bundleId: "com.example.penciltutor",
      appAppleId: undefined,
      environments: ["sandbox"],
      onlineChecks: true,
      monthlySeconds: 28_800,
    });
  });

  it("production needs the numeric app Apple id", () => {
    assert.deepEqual(appStoreConfig({ ...GOOD_ENV, APPLE_IAP_ENVIRONMENTS: "production" }), { ok: false, reason: "APPLE_APP_APPLE_ID is not set (needed for production)" });
    assert.deepEqual(appStoreConfig({ ...GOOD_ENV, APPLE_IAP_ENVIRONMENTS: "production", APPLE_APP_APPLE_ID: "abc" }), { ok: false, reason: "APPLE_APP_APPLE_ID must be a number" });
    const both = appStoreConfig({ ...GOOD_ENV, APPLE_IAP_ENVIRONMENTS: "Production, sandbox", APPLE_APP_APPLE_ID: "6740000001", APPLE_ONLINE_CHECKS: "0", IAP_MONTHLY_MINUTES: "600" });
    assert.ok(both.ok);
    assert.deepEqual([both.config.environments, both.config.appAppleId, both.config.onlineChecks, both.config.monthlySeconds], [["production", "sandbox"], 6740000001, false, 36_000]);
  });

  it("refuses unknown environments and bad minutes", () => {
    assert.equal(appStoreConfig({ ...GOOD_ENV, APPLE_IAP_ENVIRONMENTS: "xcode" }).ok, false);
    assert.equal(appStoreConfig({ ...GOOD_ENV, IAP_MONTHLY_MINUTES: "lots" }).ok, false);
  });
});

const config: AppStoreConfig = { productId: "penciltutor.monthly", bundleId: "com.example.penciltutor", appAppleId: undefined, environments: ["sandbox"], onlineChecks: false, monthlySeconds: 28_800 };
const decoded = {
  transactionId: "2000000000000002",
  originalTransactionId: "2000000000000001",
  productId: "penciltutor.monthly",
  bundleId: "com.example.penciltutor",
  type: "Auto-Renewable Subscription",
  purchaseDate: Date.UTC(2026, 10, 14),
  expiresDate: Date.UTC(2026, 11, 14),
  signedDate: Date.UTC(2026, 10, 14, 1),
  environment: "Sandbox",
};

describe("toVerifiedTransaction", () => {
  it("keeps what the server needs, as dates", () => {
    const r = toVerifiedTransaction(decoded, config);
    assert.ok(r.ok);
    assert.deepEqual(
      [r.value.transactionId, r.value.originalTransactionId, r.value.environment, r.value.expiresAt.toISOString(), r.value.revokedAt],
      ["2000000000000002", "2000000000000001", "sandbox", "2026-12-14T00:00:00.000Z", null],
    );
    const refunded = toVerifiedTransaction({ ...decoded, revocationDate: Date.UTC(2026, 10, 20) }, config);
    assert.ok(refunded.ok);
    assert.equal(refunded.value.revokedAt?.toISOString(), "2026-11-20T00:00:00.000Z");
  });

  it("refuses another app, another product, a non-subscription, and an incomplete transaction", () => {
    assert.deepEqual(toVerifiedTransaction({ ...decoded, bundleId: "com.other.app" }, config), { ok: false, kind: "wrong_app", label: "bundle_id_mismatch" });
    assert.deepEqual(toVerifiedTransaction({ ...decoded, productId: "other" }, config), { ok: false, kind: "wrong_product", label: "product_not_ours" });
    assert.deepEqual(toVerifiedTransaction({ ...decoded, type: "Consumable" }, config), { ok: false, kind: "wrong_product", label: "not_a_subscription" });
    assert.deepEqual(toVerifiedTransaction({ ...decoded, expiresDate: undefined }, config), { ok: false, kind: "invalid", label: "transaction_incomplete" });
    assert.deepEqual(toVerifiedTransaction({ ...decoded, environment: "Xcode" }, config), { ok: false, kind: "invalid", label: "transaction_incomplete" });
  });
});

// A string shaped like an Apple JWS (three parts) with the given payload. It is not signed, so verification must refuse it.
const encoded = (part: unknown) => Buffer.from(JSON.stringify(part)).toString("base64url");
const jwsLike = (payload: unknown) => `${encoded({ alg: "ES256" })}.${encoded(payload)}.c2ln`;

describe("peekEnvironment and the real verifier", () => {
  it("reads the environment named in a payload without trusting it", () => {
    assert.equal(peekEnvironment(jwsLike({ environment: "Sandbox" })), "sandbox");
    assert.equal(peekEnvironment(jwsLike({ data: { environment: "Production" } })), "production");
    assert.equal(peekEnvironment(jwsLike({ environment: "Xcode" })), null);
    assert.equal(peekEnvironment("not-a-jws"), null);
  });

  it("builds the verifier from the embedded root and refuses strings Apple never signed, without calling Apple", async () => {
    const gateway = createAppStoreGateway(config);
    const junk = await gateway.verifyTransaction("not-a-jws");
    assert.deepEqual(junk, { ok: false, kind: "invalid", label: "not_a_valid_apple_payload" });

    const unsigned = await gateway.verifyTransaction(jwsLike({ ...decoded }));
    assert.equal(unsigned.ok, false, "an unsigned payload is refused");

    const notification = await gateway.verifyNotification(jwsLike({ notificationType: "DID_RENEW", data: { environment: "Sandbox" } }));
    assert.equal(notification.ok, false);
  });

  it("does not accept an environment that is not configured", async () => {
    const gateway = createAppStoreGateway(config);
    const production = await gateway.verifyTransaction(jwsLike({ ...decoded, environment: "Production" }));
    assert.deepEqual(production, { ok: false, kind: "environment_not_accepted", label: "production_not_accepted" });
  });
});

describe("idHash", () => {
  it("is 8 hex characters and does not contain the id", () => {
    assert.match(idHash("2000000000000001"), /^[0-9a-f]{8}$/);
    assert.notEqual(idHash("2000000000000001"), idHash("2000000000000002"));
  });
});
