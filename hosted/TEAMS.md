# Relay for Teams

A company signs in with its identity provider, and every member's usage runs
through the company's account instead of personal keys.

**Status:** phase 1 is built and deployed (key mode, Google/Microsoft/any-OIDC
sign-in, per-member usage, admin console, policy). No seat licensing: the
first company is Kevel, on its own key. Setup steps are at the end.

## The one decision that shapes everything

Never put a shared API key on anyone's Mac. A key in a hundred Keychains is a
key that leaks, cannot be metered per person, and cannot be revoked without
rotating it for everyone. The Relay API already proxies translation for
hosted customers with a per-device token; a team is that same proxy with a
tenant in front of it. The company's key, if it has one, lives on the server,
encrypted, and is used there.

## Two ways a team can pay

| | **Key mode** | **Credits mode** |
|---|---|---|
| Whose provider key | The company's own Anthropic or OpenAI key, stored encrypted on the Relay API | Relay's |
| Where text goes | To the company's own provider account, under its own data agreement | To the provider under Relay's |
| What the company pays Relay | A per-seat licence | Per-minute usage from a prepaid pool, same rates as individuals |
| What the company pays the provider | Its own bill, at its negotiated rates | Nothing |
| Who it suits | Anyone with an existing OpenAI or Anthropic relationship, security review, or zero-retention terms | Small teams who want one invoice |

Key mode is the default pitch. Companies that care about where conversation
text goes already have a provider contract; Relay lets them use it without
handing the key to every laptop. Credits mode reuses the prepaid balance that
individual Relay Hosted is moving to.

## Sign-in

Standard OIDC with PKCE, through the system browser, finishing on the
`relay://activate` link the app already handles.

```
Relay.app  ──"Sign in with your company", work email──▶  Relay API
Relay API  ──302──▶  IdP (Google / Microsoft / Okta …) ──sign in──▶ Relay API /auth/callback
Relay API  verifies the ID token, matches the org (hosted domain or group claim),
           creates the member on first sight, mints a device token (hash stored),
           ──302──▶  relay://activate?token=…  ──▶  Relay.app stores it in the Keychain
```

- **Google Workspace and Microsoft Entra** work with Relay's own OAuth apps and
  a verified domain: the admin proves the domain once and every employee can
  sign in with the account they already have. No IdP configuration.
- **Okta, Auth0, anything OIDC** is the enterprise path: the admin registers
  Relay in their IdP and pastes issuer, client id and secret.
- **SAML** is not planned. Every IdP that speaks SAML also speaks OIDC.
- Device tokens are long-lived but the org sets a **re-authentication period**
  (default 30 days). That is how a departed employee loses access even before
  anyone thinks to revoke them. SCIM deprovisioning can come later; the
  re-auth window covers most of it.

## Admin console

Rendered by the Worker, signed into with the same SSO. Deliberately small.

1. **Create the org**: name, verify a domain (DNS TXT record, or by signing in
   with a Google/Microsoft admin account on that domain).
2. **Choose the mode**: paste a provider key (encrypted at rest, never shown
   again, rotate by pasting a new one) or buy credits.
3. **Policy**: allow Instant mode; allow transcripts; allow the microphone
   source; allowed target languages. Enforced on the server and reflected in
   the app, which hides what the policy forbids.
4. **Limits**: per-member monthly cap, org monthly cap, seat limit.
5. **People**: everyone who has signed in, last seen, this month's minutes,
   revoke. An allow-list or group claim if the whole domain shouldn't have access.
6. **Usage**: by month and member, CSV export, and the Stripe invoice.
7. **Audit log** of admin actions.

## What the app shows

Settings gains **Sign in with your company** next to the personal options.
After sign-in: *Signed in as dylan@kevel.co · Kevel*, this month's minutes,
and the mode ("Kevel's OpenAI account" or "Kevel's credits"). Provider and key
rows disappear; the engine picker becomes Local / Instant, minus anything the
policy forbids. Sign out revokes the device.

## Privacy posture, stated plainly

Relay stores minutes, members and devices. It never stores audio or text. In
key mode, text goes only to the company's own provider account. Audio leaves
the Mac only in Instant mode, and an admin can turn Instant mode off for the
whole company.

## Data model (D1)

```
orgs           id, name, mode (key|credits), provider, key_ciphertext, key_nonce,
               reauth_days, member_cap_cents, org_cap_cents, seat_limit, policy_json, created_at
org_domains    org_id, domain, verified_at, method
org_idps       org_id, issuer, client_id, client_secret_ciphertext, group_claim, allowed_groups
members        id, org_id, email, idp_subject, role (admin|member), status, first_seen, last_seen
devices        hash, member_id, name, created_at, last_used_at, reauth_by, revoked_at
credit_ledger  entity_type (org|customer), entity_id, delta_cents, reason, stripe_ref, created_at
usage_daily    org_id, member_id, day, local_minutes, instant_seconds
audit_log      org_id, actor_member_id, action, target, created_at
```

Metering: one Durable Object per **org**, holding per-member counters. A
single object per tenant means the org cap and every member cap are checked
in the same place that changes them, so they cannot race. Daily rollups go to
`usage_daily` for the console and export.

Key encryption: AES-256-GCM with a key-encryption key held as a Worker secret.
Decrypted in memory per request; never returned by any endpoint.

## Worker changes

- `auth.ts`: a principal becomes `{ customerId }` **or** `{ orgId, memberId }`.
- `translate.ts` / `realtime.ts`: resolve the provider key from the principal
  (org key, or Relay's); meter against the org object; refuse what the policy
  forbids (Instant off → 403 with a plain message).
- New: `/auth/start`, `/auth/callback`, `/admin/*` pages, `/v1/org/*` for the
  app (policy and usage), Stripe invoicing per org.

## Pricing to decide

Suggested, not settled: **$4 per active member per month** in key mode (a
member is active if they listened at all that month), invoiced to the org.
Credits mode: the same per-minute rates as individual Relay Hosted, drawn from
the org pool, and no seat fee. A minimum of five seats keeps it a team product.

## Phases

1. **Core**: orgs, domain verification, Google and Microsoft sign-in with
   Relay's OAuth apps, key mode, per-member and org caps, the small admin
   console, the app's company sign-in. This is the product.
2. **Money and control**: credits mode (shared with the individual rework),
   policy controls, usage export, Stripe invoicing.
3. **Enterprise**: generic OIDC (Okta and friends), audit log, SCIM
   deprovisioning, allow-lists and group claims.

## Open questions

- Pricing, above.
- Is key mode the headline, or credits? (Recommendation: key mode.)
- Google + Microsoft only for phase 1, or is there a customer on Okta already?
- Should an org be able to run Relay entirely on its own infrastructure
  (self-hosted Worker)? It is an MIT codebase; a `wrangler deploy` guide would
  make that a documentation task rather than a product.

## Setting up a company (what exists today)

1. **Create an OAuth client at the identity provider.** For Google Workspace:
   Google Cloud Console → APIs & Services → Credentials → *Create credentials →
   OAuth client ID*, type *Web application*, authorized redirect URI
   `https://api.relay-9cf.workers.dev/auth/callback`. Set the OAuth
   consent screen to *Internal* so only the Workspace can sign in. Copy the
   client id and secret. (Microsoft Entra: an app registration with the same
   redirect URI; the issuer is `https://login.microsoftonline.com/<tenant>/v2.0`.)

2. **Create the company on Relay**, from your own terminal:

   ```bash
   BOOTSTRAP_SECRET=… IDP_CLIENT_ID=… IDP_CLIENT_SECRET=… \
     ./hosted/scripts/org-bootstrap.sh kevel "Kevel" kevel.co dhulser@kevel.co
   ```

   The bootstrap secret was generated at deploy time; whoever deployed has it.

3. **Sign in to the console** at
   `https://api.relay-9cf.workers.dev/admin/login` with an admin
   address, paste the provider key (OpenAI for Luna and Instant mode, Anthropic
   for Claude models), pick the Local model, set the policy and limits.

4. **Members** open Relay → Settings → *Sign in with your company*, enter
   their work email, sign in with Google, and are done. They appear in the
   console the moment they sign in; minutes appear as they listen.

What the console shows: every person, last seen, this month's Local and
Instant minutes, how many Macs, and buttons to sign someone out everywhere,
suspend, or make admin. A CSV per month. Per-person and company-wide monthly
limits, at list rates, so one runaway session cannot surprise anyone.
