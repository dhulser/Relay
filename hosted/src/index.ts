import type { Env } from "./env";
import { json, problem } from "./env";
import { authenticate, mintToken, revokeToken, usable } from "./auth";
import { createCheckoutSession, createPortalSession, retrieveCheckoutSession, verifyWebhook } from "./stripe";
import { meterFor } from "./meter";
import { orgMeterFor } from "./orgmeter";
import { translate } from "./translate";
import { realtime } from "./realtime";
import { activatedPage, alreadyActivatedPage, companyActivatedPage, notPaidPage, refusedPage } from "./pages";
import { admin, adminCookie, bootstrap } from "./admin";
import { authorizeURL, discover, exchangeCode, pkce, verifyWithIssuer } from "./oidc";
import { domainOf, idpFor, mintDevice, orgById, orgDomains, orgForEmail, upsertMember } from "./orgs";

export { CustomerMeter } from "./meter";
export { OrgMeter } from "./orgmeter";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    try {
      switch (route) {
        case "GET /":
          return Response.redirect(env.SITE_URL, 302);
        case "GET /health":
          // Reports which secrets are present, never their values. Cloudflare
          // secrets belong to a Worker, so renaming or recreating one leaves
          // it with none; without this that failure only shows up as a
          // confusing 401 at the first request that needs one.
          return json({
            ok: true,
            configured: {
              orgKek: !!env.ORG_KEK,
              bootstrap: !!env.BOOTSTRAP_SECRET,
              openai: !!env.OPENAI_API_KEY,
              stripe: !!env.STRIPE_SECRET_KEY,
            },
          });

        // ---- individual signup (Stripe)
        case "POST /v1/checkout": {
          const session = await createCheckoutSession(env, url.origin);
          if (!session.url) return problem(502, "Stripe did not return a checkout link.");
          return json({ url: session.url });
        }
        case "GET /activated":
          return activated(url, env);
        case "POST /webhooks/stripe":
          return stripeWebhook(request, env);

        // ---- company sign-in (OIDC)
        case "GET /auth/start":
          return authStart(url, env);
        case "GET /auth/callback":
          return authCallback(url, env);
        case "POST /admin/bootstrap":
          return bootstrap(request, env);
      }
      if (url.pathname === "/admin" || url.pathname.startsWith("/admin/")) return admin(request, env);

      // Everything below needs a token.
      const who = await authenticate(request, env);
      if (!who) return problem(401, "Sign in to Relay first.");
      if (!usable(who)) return problem(402, "Your Relay Hosted subscription is not active. Check billing in Settings.");

      switch (route) {
        case "POST /v1/translate":
          return translate(request, env, who);
        case "GET /v1/realtime":
          return realtime(request, env, who);
        case "GET /v1/me":
          return me(env, who);
        case "POST /v1/portal": {
          if (who.kind !== "customer") return problem(400, "Billing is handled by your company.");
          const session = await createPortalSession(env, who.customerId, `${env.SITE_URL}pricing.html`);
          return json({ url: session.url });
        }
        case "POST /v1/tokens": {
          if (who.kind !== "customer") return problem(400, "Sign in with your company on the other Mac instead.");
          return json({ token: await mintToken(env, who.customerId) });
        }
        case "POST /v1/signout":
          await revokeToken(env, who);
          return json({ ok: true });
      }
      return problem(404, "No such endpoint.");
    } catch (error) {
      console.error(route, String(error));
      return problem(500, "Something went wrong on our side.");
    }
  },
} satisfies ExportedHandler<Env>;

/** What the app shows in Settings: who you are, what you may do, what you used. */
async function me(env: Env, who: Awaited<ReturnType<typeof authenticate>> & object): Promise<Response> {
  if (who.kind === "customer") {
    const usage = await meterFor(env, who.customerId).usage();
    return json({ kind: "customer", status: who.status, ...usage });
  }
  const org = await orgById(env, who.orgId);
  if (!org) return problem(403, "Your company's Relay account no longer exists.");
  const usage = await orgMeterFor(env, who.orgId, who.memberId, { memberCapCents: org.memberCapCents, orgCapCents: org.orgCapCents }).usage();
  return json({
    kind: "member",
    status: "active",
    org: { id: org.id, name: org.name, localModel: org.localModel, hasOpenAI: org.hasOpenAI, hasAnthropic: org.hasAnthropic },
    member: { email: who.email, role: who.role },
    policy: org.policy,
    reauthBy: who.reauthBy,
    month: usage.month,
    localMinutes: usage.localMinutes,
    instantSeconds: usage.instantSeconds,
    estimatedCents: usage.estimatedCents,
    capCents: org.memberCapCents,
  });
}

// ---------------------------------------------------------------- company sign-in

async function authStart(url: URL, env: Env): Promise<Response> {
  const email = (url.searchParams.get("email") ?? "").trim().toLowerCase();
  const purpose = url.searchParams.get("purpose") === "admin" ? "admin" : "app";
  if (!domainOf(email)) return refusedPage("Enter your work email address.");

  const org = await orgForEmail(env, email);
  if (!org) return refusedPage(`No company on Relay uses the domain <strong>${domainOf(email)}</strong>.`);
  const idp = await idpFor(env, org.id);
  if (!idp) return refusedPage(`${org.name} has not finished setting up sign-in.`);

  const doc = await discover(idp.issuer);
  const { verifier, state } = pkce();
  await env.DB.prepare("INSERT INTO oauth_states (state, org_id, code_verifier, purpose, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(state, org.id, verifier, purpose, Date.now()).run();
  const redirect = await authorizeURL(doc, idp.clientId, `${url.origin}/auth/callback`, state, verifier, email);
  return Response.redirect(redirect, 302);
}

async function authCallback(url: URL, env: Env): Promise<Response> {
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (url.searchParams.get("error")) return refusedPage(`Your identity provider said: ${url.searchParams.get("error_description") ?? url.searchParams.get("error")}.`);
  if (!code || !state) return refusedPage("The sign-in link was incomplete.");

  const pending = await env.DB.prepare("SELECT org_id, code_verifier, purpose, created_at FROM oauth_states WHERE state = ?")
    .bind(state).first<{ org_id: string; code_verifier: string; purpose: string; created_at: number }>();
  await env.DB.prepare("DELETE FROM oauth_states WHERE state = ? OR created_at < ?").bind(state, Date.now() - 600_000).run();
  if (!pending || Date.now() - pending.created_at > 600_000) return refusedPage("That sign-in took too long. Start again from Relay.");

  const org = await orgById(env, pending.org_id);
  const idp = org ? await idpFor(env, org.id) : null;
  if (!org || !idp) return refusedPage("The company account changed while you were signing in.");

  const doc = await discover(idp.issuer);
  const { id_token } = await exchangeCode(doc, idp.clientId, idp.clientSecret, `${url.origin}/auth/callback`, code, pending.code_verifier);
  const claims = await verifyWithIssuer(id_token, doc, idp.clientId);

  const domains = await orgDomains(env, org.id);
  const domain = domainOf(claims.email!);
  if (!domain || !domains.includes(domain)) return refusedPage(`<strong>${claims.email}</strong> is not an address at ${org.name}.`);

  const member = await upsertMember(env, org, claims);
  if (member.status !== "active") return refusedPage(`Your access to ${org.name}'s Relay has been suspended.`);

  if (pending.purpose === "admin") {
    if (member.role !== "admin") return refusedPage(`You are signed in, but only admins can open the console. Ask an admin at ${org.name} to make you one.`);
    const token = await mintDevice(env, member.id, "browser", org.reauthDays);
    return new Response(null, { status: 302, headers: { location: `${url.origin}/admin`, "set-cookie": adminCookie(token) } });
  }

  const token = await mintDevice(env, member.id, "app", org.reauthDays);
  return companyActivatedPage(token, org.name, member.email);
}

// ---------------------------------------------------------------- individual (Stripe)

async function activated(url: URL, env: Env): Promise<Response> {
  const sessionId = url.searchParams.get("session_id") ?? "";
  if (!sessionId.startsWith("cs_")) return problem(400, "Missing checkout session.");

  const claimed = await env.DB.prepare("SELECT 1 FROM checkout_claims WHERE session_id = ?").bind(sessionId).first();
  if (claimed) return alreadyActivatedPage();

  const session = await retrieveCheckoutSession(env, sessionId);
  const subscription = typeof session.subscription === "object" ? session.subscription : null;
  if (session.status !== "complete" || !session.customer || !subscription) return notPaidPage();

  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO customers (id, subscription_id, status, email, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET subscription_id = excluded.subscription_id,
         status = excluded.status, email = COALESCE(excluded.email, customers.email), updated_at = excluded.updated_at`,
    ).bind(session.customer, subscription.id, subscription.status, session.customer_details?.email ?? null, now, now),
    env.DB.prepare("INSERT INTO checkout_claims (session_id, customer_id, claimed_at) VALUES (?, ?, ?)").bind(sessionId, session.customer, now),
  ]);
  return activatedPage(await mintToken(env, session.customer));
}

interface SubscriptionEvent {
  type: string;
  data: { object: { id: string; customer: string; status: string } };
}

async function stripeWebhook(request: Request, env: Env): Promise<Response> {
  const payload = await request.text();
  const valid = await verifyWebhook(payload, request.headers.get("stripe-signature"), env.STRIPE_WEBHOOK_SECRET);
  if (!valid) return problem(400, "Bad signature.");
  const event = JSON.parse(payload) as SubscriptionEvent;
  if (event.type.startsWith("customer.subscription.")) {
    const sub = event.data.object;
    const status = event.type === "customer.subscription.deleted" ? "canceled" : sub.status;
    await env.DB.prepare("UPDATE customers SET status = ?, subscription_id = ?, updated_at = ? WHERE id = ?")
      .bind(status, sub.id, Date.now(), sub.customer).run();
  }
  return json({ received: true });
}
