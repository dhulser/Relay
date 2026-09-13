import { describe, expect, it } from "vitest";
import { verifyWebhook } from "../src/stripe";

async function sign(payload: string, secret: string, t: number): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${payload}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("webhook signatures", () => {
  const secret = "whsec_test";
  const payload = '{"type":"customer.subscription.updated"}';

  it("accepts a fresh, correctly signed payload", async () => {
    const t = Math.floor(Date.now() / 1000);
    const header = `t=${t},v1=${await sign(payload, secret, t)}`;
    expect(await verifyWebhook(payload, header, secret)).toBe(true);
  });

  it("rejects a tampered payload", async () => {
    const t = Math.floor(Date.now() / 1000);
    const header = `t=${t},v1=${await sign(payload, secret, t)}`;
    expect(await verifyWebhook(payload + " ", header, secret)).toBe(false);
  });

  it("rejects a stale timestamp", async () => {
    const t = Math.floor(Date.now() / 1000) - 3600;
    const header = `t=${t},v1=${await sign(payload, secret, t)}`;
    expect(await verifyWebhook(payload, header, secret)).toBe(false);
  });

  it("rejects a missing header", async () => {
    expect(await verifyWebhook(payload, null, secret)).toBe(false);
  });
});
