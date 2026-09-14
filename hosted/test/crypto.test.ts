import { describe, expect, it } from "vitest";
import { open, seal, toBase64 } from "../src/crypto";

const KEK = toBase64(crypto.getRandomValues(new Uint8Array(32)));

describe("sealed secrets", () => {
  it("round-trips a provider key", async () => {
    const { ciphertext, iv } = await seal("sk-proj-abc123", KEK);
    expect(ciphertext).not.toContain("sk-proj");
    expect(await open(ciphertext, iv, KEK)).toBe("sk-proj-abc123");
  });

  it("uses a fresh nonce each time", async () => {
    const a = await seal("same", KEK);
    const b = await seal("same", KEK);
    expect(a.ciphertext).not.toBe(b.ciphertext);
  });

  it("refuses the wrong key", async () => {
    const { ciphertext, iv } = await seal("secret", KEK);
    const other = toBase64(crypto.getRandomValues(new Uint8Array(32)));
    await expect(open(ciphertext, iv, other)).rejects.toThrow();
  });

  it("insists on a 32-byte key", async () => {
    await expect(seal("x", toBase64(new Uint8Array(16)))).rejects.toThrow(/32 bytes/);
  });
});
