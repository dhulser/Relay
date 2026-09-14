import { beforeAll, describe, expect, it } from "vitest";
import { verifyIdToken } from "../src/oidc";
import { toBase64Url } from "../src/crypto";

// Sign our own ID tokens with a generated RSA key and verify them the way the
// Worker verifies Google's: signature against a JWK set, then the claims.

let privateKey: CryptoKey;
let jwk: JsonWebKey;

function b64(obj: unknown): string {
  return toBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
}

async function token(claims: Record<string, unknown>, kid = "k1"): Promise<string> {
  const head = b64({ alg: "RS256", kid });
  const body = b64(claims);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${toBase64Url(new Uint8Array(sig))}`;
}

const good = () => ({
  iss: "https://accounts.google.com", aud: "client-1", sub: "1234", exp: Math.floor(Date.now() / 1000) + 300,
  email: "dylan@kevel.co", email_verified: true, name: "Dylan", hd: "kevel.co",
});

beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  privateKey = pair.privateKey;
  jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1" } as unknown as JsonWebKey;
});

describe("ID token verification", () => {
  it("accepts a well-signed token for the right client", async () => {
    const claims = await verifyIdToken(await token(good()), "https://accounts.google.com", "client-1", [jwk]);
    expect(claims.email).toBe("dylan@kevel.co");
    expect(claims.sub).toBe("1234");
  });

  it("accepts Google's bare issuer spelling", async () => {
    const claims = await verifyIdToken(await token({ ...good(), iss: "accounts.google.com" }), "https://accounts.google.com", "client-1", [jwk]);
    expect(claims.email).toBe("dylan@kevel.co");
  });

  it("rejects a token for another client", async () => {
    await expect(verifyIdToken(await token({ ...good(), aud: "someone-else" }), "https://accounts.google.com", "client-1", [jwk])).rejects.toThrow(/audience/);
  });

  it("rejects an expired token", async () => {
    await expect(verifyIdToken(await token({ ...good(), exp: Math.floor(Date.now() / 1000) - 3600 }), "https://accounts.google.com", "client-1", [jwk])).rejects.toThrow(/expired/);
  });

  it("rejects a tampered payload", async () => {
    const t = await token(good());
    const [h, , s] = t.split(".");
    const forged = `${h}.${b64({ ...good(), email: "attacker@kevel.co" })}.${s}`;
    await expect(verifyIdToken(forged, "https://accounts.google.com", "client-1", [jwk])).rejects.toThrow(/signature/);
  });

  it("rejects an unverified email", async () => {
    await expect(verifyIdToken(await token({ ...good(), email_verified: false }), "https://accounts.google.com", "client-1", [jwk])).rejects.toThrow(/verified/);
  });

  it("rejects a key it does not know", async () => {
    await expect(verifyIdToken(await token(good(), "other-kid"), "https://accounts.google.com", "client-1", [jwk])).rejects.toThrow(/signing key/);
  });
});
