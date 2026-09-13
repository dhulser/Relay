import type { Env } from "./env";
import { json, problem } from "./env";
import { authenticate, mintToken, revokeToken, usable } from "./auth";
import { createCheckoutSession, createPortalSession, retrieveCheckoutSession, verifyWebhook } from "./stripe";
import { meterFor } from "./meter";
import { translate } from "./translate";
import { realtime } from "./realtime";
import { activatedPage, alreadyActivatedPage, notPaidPage } from "./pages";

export { CustomerMeter } from "./meter";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    try {
      switch (route) {
        case "GET /":
          return Response.redirect(env.SITE_URL, 302);
        case "GET /health":
          return json({ ok: true });

        // ---- signup
        case "POST /v1/checkout": {
          const session = await createCheckoutSession(env, url.origin);
          if (!session.url) return problem(502, "Stripe did not return a checkout link.");
          return json({ url: session.url });
        }
        case "GET /activated":
          return activated(url, env);

        // ---- webhooks
        case "POST /webhooks/stripe":
          return stripeWebhook(request, env);
      }

      // Everything below needs a token.
      const who = await authenticate(request, env);
      if (!who) return problem(401, "Sign in to Relay Hosted first.");
      if (!usable(who.status)) return problem(402, "Your Relay Hosted subscription is not active. Check billing in Settings.");

      switch (route) {
        case "POST /v1/translate":
          return translate(request, env, who);
        case "GET /v1/realtime":
          return realtime(request, env, who);
        case "GET /v1/me": {
          const usage = await meterFor(env, who.customerId).usage();
          return json({ status: who.status, ...usage });
        }
        case "POST /v1/portal": {
          const session = await createPortalSession(env, who.customerId, `${env.SITE_URL}pricing.html`);
          return json({ url: session.url });
        }
        case "POST /v1/tokens": {
          // Another Mac: mint a second token for the same customer.
          const token = await mintToken(env, who.customerId);
          return json({ token });
        }
        case "POST /v1/signout":
          await revokeToken(env, who.tokenHash);
          return json({ ok: true });
      }
      return problem(404, "No such endpoint.");
    } catch (error) {
      console.error(route, String(error));
      return problem(500, "Something went wrong on our side.");
    }
  },
} satisfies ExportedHandler<Env>;

/** The Checkout success page. Mints one token per paid session, ever. */
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
    env.DB.prepare("INSERT INTO checkout_claims (session_id, customer_id, claimed_at) VALUES (?, ?, ?)")
      .bind(sessionId, session.customer, now),
  ]);

  const token = await mintToken(env, session.customer);
  return activatedPage(token);
}

interface SubscriptionEvent {
  type: string;
  data: { object: { id: string; customer: string; status: string; metadata?: Record<string, string> } };
}

/** Keeps our copy of the subscription status current. */
async function stripeWebhook(request: Request, env: Env): Promise<Response> {
  const payload = await request.text();
  const valid = await verifyWebhook(payload, request.headers.get("stripe-signature"), env.STRIPE_WEBHOOK_SECRET);
  if (!valid) return problem(400, "Bad signature.");

  const event = JSON.parse(payload) as SubscriptionEvent;
  if (event.type.startsWith("customer.subscription.")) {
    const sub = event.data.object;
    const status = event.type === "customer.subscription.deleted" ? "canceled" : sub.status;
    await env.DB.prepare("UPDATE customers SET status = ?, subscription_id = ?, updated_at = ? WHERE id = ?")
      .bind(status, sub.id, Date.now(), sub.customer)
      .run();
  }
  return json({ received: true });
}
