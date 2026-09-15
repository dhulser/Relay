import type { Env } from "./env";
import { open, randomId, randomToken, seal, sha256Hex } from "./crypto";
import type { IdentityClaims } from "./oidc";

/// What a new company starts with, per person per month, at list rates.
/// About twelve hours of Local mode. Admins change it in the console.
export const DEFAULT_MEMBER_CAP_CENTS = 500;

export interface Policy {
  allowInstant: boolean;
  allowTranscript: boolean;
  allowMicrophone: boolean;
}

export interface Org {
  id: string;
  name: string;
  localModel: string;
  allowModelChoice: boolean;
  reauthDays: number;
  memberCapCents: number;
  orgCapCents: number;
  policy: Policy;
  adminEmails: string[];
  hasOpenAI: boolean;
  hasAnthropic: boolean;
}

interface OrgRow {
  id: string; name: string; local_model: string; reauth_days: number; allow_model_choice: number;
  member_cap_cents: number; org_cap_cents: number; policy_json: string; admin_emails: string;
  openai_key_ciphertext: string | null; openai_key_iv: string | null;
  anthropic_key_ciphertext: string | null; anthropic_key_iv: string | null;
}

export function parsePolicy(json: string | null | undefined): Policy {
  const defaults: Policy = { allowInstant: true, allowTranscript: true, allowMicrophone: true };
  if (!json) return defaults;
  try {
    const parsed = JSON.parse(json) as Partial<Policy>;
    return {
      allowInstant: parsed.allowInstant !== false,
      allowTranscript: parsed.allowTranscript !== false,
      allowMicrophone: parsed.allowMicrophone !== false,
    };
  } catch {
    return defaults;
  }
}

function toOrg(row: OrgRow): Org {
  let admins: string[] = [];
  try { admins = JSON.parse(row.admin_emails) as string[]; } catch { /* keep empty */ }
  return {
    id: row.id, name: row.name, localModel: row.local_model, allowModelChoice: !!row.allow_model_choice,
    reauthDays: row.reauth_days,
    memberCapCents: row.member_cap_cents, orgCapCents: row.org_cap_cents,
    policy: parsePolicy(row.policy_json), adminEmails: admins.map((e) => e.toLowerCase()),
    hasOpenAI: !!row.openai_key_ciphertext, hasAnthropic: !!row.anthropic_key_ciphertext,
  };
}

const ORG_COLUMNS = `id, name, local_model, allow_model_choice, reauth_days, member_cap_cents, org_cap_cents, policy_json, admin_emails,
  openai_key_ciphertext, openai_key_iv, anthropic_key_ciphertext, anthropic_key_iv`;

export function domainOf(email: string): string | null {
  const at = email.lastIndexOf("@");
  if (at < 1 || at === email.length - 1) return null;
  return email.slice(at + 1).toLowerCase();
}

export async function orgById(env: Env, id: string): Promise<Org | null> {
  const row = await env.DB.prepare(`SELECT ${ORG_COLUMNS} FROM orgs WHERE id = ?`).bind(id).first<OrgRow>();
  return row ? toOrg(row) : null;
}

export async function orgForEmail(env: Env, email: string): Promise<Org | null> {
  const domain = domainOf(email);
  if (!domain) return null;
  const row = await env.DB.prepare(
    `SELECT ${ORG_COLUMNS} FROM orgs WHERE id = (SELECT org_id FROM org_domains WHERE domain = ?)`,
  ).bind(domain).first<OrgRow>();
  return row ? toOrg(row) : null;
}

export async function orgDomains(env: Env, orgId: string): Promise<string[]> {
  const { results } = await env.DB.prepare("SELECT domain FROM org_domains WHERE org_id = ? ORDER BY domain").bind(orgId).all<{ domain: string }>();
  return results.map((r) => r.domain);
}

/** The org's provider keys, decrypted for one request. */
export async function orgKeys(env: Env, orgId: string): Promise<{ openai?: string; anthropic?: string }> {
  const row = await env.DB.prepare(
    "SELECT openai_key_ciphertext, openai_key_iv, anthropic_key_ciphertext, anthropic_key_iv FROM orgs WHERE id = ?",
  ).bind(orgId).first<OrgRow>();
  if (!row) return {};
  const keys: { openai?: string; anthropic?: string } = {};
  if (row.openai_key_ciphertext && row.openai_key_iv) keys.openai = await open(row.openai_key_ciphertext, row.openai_key_iv, env.ORG_KEK);
  if (row.anthropic_key_ciphertext && row.anthropic_key_iv) keys.anthropic = await open(row.anthropic_key_ciphertext, row.anthropic_key_iv, env.ORG_KEK);
  return keys;
}

export async function setOrgKey(env: Env, orgId: string, provider: "openai" | "anthropic", value: string | null): Promise<void> {
  const column = provider === "openai" ? "openai_key" : "anthropic_key";
  if (value) {
    const sealed = await seal(value.trim(), env.ORG_KEK);
    await env.DB.prepare(`UPDATE orgs SET ${column}_ciphertext = ?, ${column}_iv = ?, updated_at = ? WHERE id = ?`)
      .bind(sealed.ciphertext, sealed.iv, Date.now(), orgId).run();
  } else {
    await env.DB.prepare(`UPDATE orgs SET ${column}_ciphertext = NULL, ${column}_iv = NULL, updated_at = ? WHERE id = ?`)
      .bind(Date.now(), orgId).run();
  }
}

export interface IdP { issuer: string; clientId: string; clientSecret: string }

export async function idpFor(env: Env, orgId: string): Promise<IdP | null> {
  const row = await env.DB.prepare("SELECT issuer, client_id, client_secret_ciphertext, client_secret_iv FROM org_idps WHERE org_id = ?")
    .bind(orgId).first<{ issuer: string; client_id: string; client_secret_ciphertext: string; client_secret_iv: string }>();
  if (!row) return null;
  return { issuer: row.issuer, clientId: row.client_id, clientSecret: await open(row.client_secret_ciphertext, row.client_secret_iv, env.ORG_KEK) };
}

export interface Member { id: string; orgId: string; email: string; role: string; status: string; name: string | null }

/** Creates the member on first sign-in, refreshes name and last_seen after. */
export async function upsertMember(env: Env, org: Org, claims: IdentityClaims): Promise<Member> {
  const email = claims.email!.toLowerCase();
  const now = Date.now();
  const existing = await env.DB.prepare("SELECT id, org_id, email, role, status, name FROM members WHERE org_id = ? AND email = ?")
    .bind(org.id, email).first<{ id: string; org_id: string; email: string; role: string; status: string; name: string | null }>();

  if (existing) {
    await env.DB.prepare("UPDATE members SET last_seen = ?, name = COALESCE(?, name), subject = ? WHERE id = ?")
      .bind(now, claims.name ?? null, claims.sub, existing.id).run();
    return { id: existing.id, orgId: existing.org_id, email, role: existing.role, status: existing.status, name: claims.name ?? existing.name };
  }

  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE org_id = ?").bind(org.id).first<{ n: number }>();
  const role = org.adminEmails.includes(email) || (count?.n ?? 0) === 0 ? "admin" : "member";
  const id = randomId();
  await env.DB.prepare(
    "INSERT INTO members (id, org_id, email, subject, name, role, status, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)",
  ).bind(id, org.id, email, claims.sub, claims.name ?? null, role, now, now).run();
  return { id, orgId: org.id, email, role, status: "active", name: claims.name ?? null };
}

/** A device token for a Mac or an admin's browser. Only the hash is kept. */
export async function mintDevice(env: Env, memberId: string, kind: "app" | "browser", reauthDays: number): Promise<string> {
  const token = randomToken();
  const now = Date.now();
  const reauthBy = now + (kind === "browser" ? 1 : reauthDays) * 86_400_000;
  await env.DB.prepare("INSERT INTO devices (hash, member_id, kind, created_at, reauth_by) VALUES (?, ?, ?, ?, ?)")
    .bind(await sha256Hex(token), memberId, kind, now, reauthBy).run();
  return token;
}

export async function revokeDevice(env: Env, hash: string): Promise<void> {
  await env.DB.prepare("UPDATE devices SET revoked_at = ? WHERE hash = ?").bind(Date.now(), hash).run();
}

export async function revokeMemberDevices(env: Env, memberId: string): Promise<void> {
  await env.DB.prepare("UPDATE devices SET revoked_at = ? WHERE member_id = ? AND revoked_at IS NULL").bind(Date.now(), memberId).run();
}

export interface MemberUsage {
  id: string; email: string; name: string | null; role: string; status: string;
  lastSeen: number; localMinutes: number; instantSeconds: number; devices: number;
}

/** Every member with their minutes for one month, from the daily rollups. */
export async function membersWithUsage(env: Env, orgId: string, month: string): Promise<MemberUsage[]> {
  const { results } = await env.DB.prepare(`
    SELECT m.id, m.email, m.name, m.role, m.status, m.last_seen,
           COALESCE(SUM(u.local_minutes), 0) AS local_minutes,
           COALESCE(SUM(u.instant_seconds), 0) AS instant_seconds,
           (SELECT COUNT(*) FROM devices d WHERE d.member_id = m.id AND d.revoked_at IS NULL AND d.kind = 'app') AS devices
      FROM members m
      LEFT JOIN usage_daily u ON u.member_id = m.id AND u.day LIKE ?
     WHERE m.org_id = ?
     GROUP BY m.id
     ORDER BY local_minutes + instant_seconds / 60 DESC, m.email`,
  ).bind(`${month}-%`, orgId).all<{ id: string; email: string; name: string | null; role: string; status: string; last_seen: number; local_minutes: number; instant_seconds: number; devices: number }>();
  return results.map((r) => ({
    id: r.id, email: r.email, name: r.name, role: r.role, status: r.status, lastSeen: r.last_seen,
    localMinutes: r.local_minutes, instantSeconds: r.instant_seconds, devices: r.devices,
  }));
}

export async function audit(env: Env, orgId: string, actor: string, action: string, detail?: string): Promise<void> {
  await env.DB.prepare("INSERT INTO audit_log (org_id, actor, action, detail, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(orgId, actor, action, detail ?? null, Date.now()).run();
}
