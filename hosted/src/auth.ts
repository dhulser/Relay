import type { Env } from "./env";

const PREFIX = "rly_";

export interface Principal {
  customerId: string;
  status: string;
  tokenHash: string;
}

/** Subscriptions in these states may use the service. past_due keeps working
 *  while Stripe retries the card; canceled and unpaid do not. */
const USABLE = new Set(["active", "trialing", "past_due"]);

export function usable(status: string): boolean {
  return USABLE.has(status);
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A fresh token: 32 random bytes. Returned once, stored only as a hash. */
export async function mintToken(env: Env, customerId: string): Promise<string> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = PREFIX + base64url(bytes);
  const now = Date.now();
  await env.DB.prepare("INSERT INTO tokens (hash, customer_id, created_at) VALUES (?, ?, ?)")
    .bind(await sha256Hex(token), customerId, now)
    .run();
  return token;
}

/** Resolves the bearer token on a request, or null. Touches last_used_at at
 *  most once an hour so a busy session doesn't write on every utterance. */
export async function authenticate(request: Request, env: Env): Promise<Principal | null> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token.startsWith(PREFIX) || token.length < 40) return null;

  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    `SELECT t.customer_id, t.last_used_at, c.status
       FROM tokens t JOIN customers c ON c.id = t.customer_id
      WHERE t.hash = ?`,
  ).bind(hash).first<{ customer_id: string; last_used_at: number | null; status: string }>();
  if (!row) return null;

  const now = Date.now();
  if (!row.last_used_at || now - row.last_used_at > 3_600_000) {
    await env.DB.prepare("UPDATE tokens SET last_used_at = ? WHERE hash = ?").bind(now, hash).run();
  }
  return { customerId: row.customer_id, status: row.status, tokenHash: hash };
}

export async function revokeToken(env: Env, tokenHash: string): Promise<void> {
  await env.DB.prepare("DELETE FROM tokens WHERE hash = ?").bind(tokenHash).run();
}
