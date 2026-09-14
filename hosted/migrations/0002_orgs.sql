-- Relay for Teams: a company signs in with its identity provider and its
-- members' usage runs through the company's own provider key, held here
-- encrypted. Relay stores minutes, members and devices; never text or audio.

CREATE TABLE orgs (
  id TEXT PRIMARY KEY,                 -- slug, e.g. "kevel"
  name TEXT NOT NULL,
  -- Provider keys, AES-256-GCM under the ORG_KEK secret. Either or both.
  openai_key_ciphertext TEXT, openai_key_iv TEXT,
  anthropic_key_ciphertext TEXT, anthropic_key_iv TEXT,
  local_model TEXT NOT NULL DEFAULT 'gpt-5.6-luna',
  reauth_days INTEGER NOT NULL DEFAULT 30,
  member_cap_cents INTEGER NOT NULL DEFAULT 2000,   -- per member per month, at list rates
  org_cap_cents INTEGER NOT NULL DEFAULT 0,          -- 0 = no org-wide cap
  policy_json TEXT NOT NULL DEFAULT '{"allowInstant":true,"allowTranscript":true,"allowMicrophone":true}',
  admin_emails TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Email domains that belong to the org. Sign-in with an address outside
-- these is refused.
CREATE TABLE org_domains (
  domain TEXT PRIMARY KEY,
  org_id TEXT NOT NULL REFERENCES orgs(id)
);

-- The org's identity provider (OIDC). One per org.
CREATE TABLE org_idps (
  org_id TEXT PRIMARY KEY REFERENCES orgs(id),
  issuer TEXT NOT NULL,                -- e.g. https://accounts.google.com
  client_id TEXT NOT NULL,
  client_secret_ciphertext TEXT NOT NULL,
  client_secret_iv TEXT NOT NULL
);

CREATE TABLE members (
  id TEXT PRIMARY KEY,                 -- random
  org_id TEXT NOT NULL REFERENCES orgs(id),
  email TEXT NOT NULL,
  subject TEXT NOT NULL,               -- the IdP's stable id for the person
  name TEXT,
  role TEXT NOT NULL DEFAULT 'member', -- member | admin
  status TEXT NOT NULL DEFAULT 'active', -- active | suspended
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  UNIQUE (org_id, email)
);

-- A signed-in Mac (or an admin's browser). Only the token hash is stored.
CREATE TABLE devices (
  hash TEXT PRIMARY KEY,
  member_id TEXT NOT NULL REFERENCES members(id),
  kind TEXT NOT NULL DEFAULT 'app',    -- app | browser
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  reauth_by INTEGER NOT NULL,          -- after this, sign in again
  revoked_at INTEGER
);
CREATE INDEX devices_member ON devices(member_id);

-- Per-person, per-day minutes for the console and CSV export.
CREATE TABLE usage_daily (
  org_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  day TEXT NOT NULL,                   -- YYYY-MM-DD, UTC
  local_minutes INTEGER NOT NULL DEFAULT 0,
  instant_seconds INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (org_id, member_id, day)
);

-- In-flight sign-ins. Expire after ten minutes.
CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  org_id TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  purpose TEXT NOT NULL,               -- app | admin
  created_at INTEGER NOT NULL
);

CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT,
  created_at INTEGER NOT NULL
);
