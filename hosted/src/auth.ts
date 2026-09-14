import type { Env } from "./env";
import { sha256Hex } from "./crypto";

const PREFIX = "rly_";

/** Who is calling: an individual hosted customer, or a member of an org. */
export type Principal =
  | { kind: "customer"; customerId: string; status: string; tokenHash: string }
  | { kind: "member"; orgId: string; memberId: string; email: string; role: string; tokenHash: string; reauthBy: number };

/** Subscriptions in these states may use the service. past_due keeps working
 *  while Stripe retries the card; canceled and unpaid do not. */
const USABLE = new Set(["active", "trialing", "past_due"]);

export function usable(who: Principal): boolean {
  return who.kind === "member" || USABLE.has(who.status);
}

export { sha256Hex };

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A fresh customer token: 32 random bytes. Returned once, stored only as a hash. */
export async function mintToken(env: Env, customerId: string): Promise<string> {
  const token = PREFIX + base64url(crypto.getRandomValues(new Uint8Array(32)));
  await env.DB.prepare("INSERT INTO tokens (hash, customer_id, created_at) VALUES (?, ?, ?)")
    .bind(await sha256Hex(token), customerId, Date.now())
    .run();
  return token;
}

export function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  return token.startsWith(PREFIX) && token.length >= 40 ? token : null;
}

/** Resolves a raw token to a principal, or null. */
export async function resolveToken(token: string, env: Env): Promise<Principal | null> {
  const hash = await sha256Hex(token);
  const now = Date.now();

  const customer = await env.DB.prepare(
    `SELECT t.customer_id, t.last_used_at, c.status
       FROM tokens t JOIN customers c ON c.id = t.customer_id
      WHERE t.hash = ?`,
  ).bind(hash).first<{ customer_id: string; last_used_at: number | null; status: string }>();
  if (customer) {
    if (!customer.last_used_at || now - customer.last_used_at > 3_600_000) {
      await env.DB.prepare("UPDATE tokens SET last_used_at = ? WHERE hash = ?").bind(now, hash).run();
    }
    return { kind: "customer", customerId: customer.customer_id, status: customer.status, tokenHash: hash };
  }

  const device = await env.DB.prepare(
    `SELECT d.member_id, d.last_used_at, d.reauth_by, d.revoked_at, m.org_id, m.email, m.role, m.status
       FROM devices d JOIN members m ON m.id = d.member_id
      WHERE d.hash = ?`,
  ).bind(hash).first<{ member_id: string; last_used_at: number | null; reauth_by: number; revoked_at: number | null; org_id: string; email: string; role: string; status: string }>();
  if (!device || device.revoked_at || device.status !== "active" || device.reauth_by < now) return null;

  if (!device.last_used_at || now - device.last_used_at > 3_600_000) {
    await env.DB.prepare("UPDATE devices SET last_used_at = ? WHERE hash = ?").bind(now, hash).run();
    await env.DB.prepare("UPDATE members SET last_seen = ? WHERE id = ?").bind(now, device.member_id).run();
  }
  return { kind: "member", orgId: device.org_id, memberId: device.member_id, email: device.email, role: device.role, tokenHash: hash, reauthBy: device.reauth_by };
}

export async function authenticate(request: Request, env: Env): Promise<Principal | null> {
  const token = bearer(request);
  return token ? resolveToken(token, env) : null;
}

export async function revokeToken(env: Env, who: Principal): Promise<void> {
  if (who.kind === "customer") {
    await env.DB.prepare("DELETE FROM tokens WHERE hash = ?").bind(who.tokenHash).run();
  } else {
    await env.DB.prepare("UPDATE devices SET revoked_at = ? WHERE hash = ?").bind(Date.now(), who.tokenHash).run();
  }
}
