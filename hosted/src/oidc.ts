// The half of OpenID Connect a relying party needs: discovery, an authorize
// URL with PKCE, the code exchange, and ID-token verification against the
// issuer's JWKS. Google Workspace, Microsoft Entra and Okta all speak this.

import { sha256Base64Url, toBase64Url } from "./crypto";

export interface Discovery {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  jwks_uri: string;
}

const discoveryCache = new Map<string, { at: number; doc: Discovery }>();
const jwksCache = new Map<string, { at: number; keys: JsonWebKey[] }>();
const TTL = 6 * 3600_000;

export async function discover(issuer: string): Promise<Discovery> {
  const hit = discoveryCache.get(issuer);
  if (hit && Date.now() - hit.at < TTL) return hit.doc;
  const response = await fetch(`${issuer.replace(/\/$/, "")}/.well-known/openid-configuration`);
  if (!response.ok) throw new Error(`OIDC discovery failed for ${issuer}: ${response.status}`);
  const doc = (await response.json()) as Discovery;
  discoveryCache.set(issuer, { at: Date.now(), doc });
  return doc;
}

export function pkce(): { verifier: string; state: string } {
  return {
    verifier: toBase64Url(crypto.getRandomValues(new Uint8Array(48))),
    state: toBase64Url(crypto.getRandomValues(new Uint8Array(24))),
  };
}

export async function authorizeURL(doc: Discovery, clientId: string, redirectUri: string, state: string, verifier: string, loginHint?: string): Promise<string> {
  const url = new URL(doc.authorization_endpoint);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("scope", "openid email profile");
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", await sha256Base64Url(verifier));
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("prompt", "select_account");
  if (loginHint) url.searchParams.set("login_hint", loginHint);
  return url.toString();
}

export async function exchangeCode(doc: Discovery, clientId: string, clientSecret: string, redirectUri: string, code: string, verifier: string): Promise<{ id_token: string }> {
  const response = await fetch(doc.token_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      client_secret: clientSecret,
      code_verifier: verifier,
    }),
  });
  const body = (await response.json()) as { id_token?: string; error?: string; error_description?: string };
  if (!response.ok || !body.id_token) throw new Error(`Token exchange failed: ${body.error_description ?? body.error ?? response.status}`);
  return { id_token: body.id_token };
}

export interface IdentityClaims {
  iss: string;
  aud: string | string[];
  sub: string;
  exp: number;
  iat?: number;
  email?: string;
  email_verified?: boolean | string;
  name?: string;
  hd?: string;            // Google: hosted domain
  tid?: string;           // Microsoft: tenant
}

function decodeSegment(segment: string): Uint8Array {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((segment.length + 3) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function fetchJWKS(uri: string): Promise<JsonWebKey[]> {
  const hit = jwksCache.get(uri);
  if (hit && Date.now() - hit.at < TTL) return hit.keys;
  const response = await fetch(uri);
  if (!response.ok) throw new Error(`JWKS fetch failed: ${response.status}`);
  const { keys } = (await response.json()) as { keys: JsonWebKey[] };
  jwksCache.set(uri, { at: Date.now(), keys });
  return keys;
}

/**
 * Verifies an RS256 ID token: signature against one of `keys`, issuer,
 * audience and expiry. `keys` is injectable so the check can be tested
 * without a network; production passes the issuer's JWKS.
 */
export async function verifyIdToken(token: string, expectedIssuer: string, clientId: string, keys: JsonWebKey[], now = Date.now()): Promise<IdentityClaims> {
  const [h, p, s] = token.split(".");
  if (!h || !p || !s) throw new Error("Malformed ID token");
  const header = JSON.parse(new TextDecoder().decode(decodeSegment(h))) as { alg: string; kid?: string };
  if (header.alg !== "RS256") throw new Error(`Unsupported ID token algorithm ${header.alg}`);

  const candidates = keys.filter((k) => !header.kid || (k as { kid?: string }).kid === header.kid);
  if (!candidates.length) throw new Error("No matching signing key");

  const data = new TextEncoder().encode(`${h}.${p}`);
  const signature = decodeSegment(s);
  let verified = false;
  for (const jwk of candidates) {
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    if (await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, data)) { verified = true; break; }
  }
  if (!verified) throw new Error("ID token signature did not verify");

  const claims = JSON.parse(new TextDecoder().decode(decodeSegment(p))) as IdentityClaims;
  const issuerOk = claims.iss === expectedIssuer || claims.iss === expectedIssuer.replace(/^https:\/\//, "");
  if (!issuerOk) throw new Error("ID token issuer mismatch");
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(clientId)) throw new Error("ID token audience mismatch");
  if (claims.exp * 1000 < now - 60_000) throw new Error("ID token expired");
  if (!claims.email) throw new Error("ID token carries no email");
  if (claims.email_verified === false || claims.email_verified === "false") throw new Error("Email is not verified with the identity provider");
  return claims;
}

export async function verifyWithIssuer(token: string, doc: Discovery, clientId: string): Promise<IdentityClaims> {
  return verifyIdToken(token, doc.issuer, clientId, await fetchJWKS(doc.jwks_uri));
}
