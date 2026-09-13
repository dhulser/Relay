import type { Env } from "./env";

// Raw Stripe REST calls. The official SDK is large and this needs six calls.

const API = "https://api.stripe.com/v1";

async function stripe<T>(env: Env, method: "GET" | "POST", path: string, form?: Record<string, string>): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      "content-type": "application/x-www-form-urlencoded",
      "stripe-version": "2025-08-27.basil",
    },
    body: form ? new URLSearchParams(form).toString() : undefined,
  });
  const body = (await response.json()) as T & { error?: { message: string } };
  if (!response.ok) throw new Error(`Stripe ${path}: ${body.error?.message ?? response.status}`);
  return body;
}

export interface CheckoutSession {
  id: string;
  url: string | null;
  status: string;
  payment_status: string;
  customer: string | null;
  customer_details?: { email?: string | null };
  subscription: string | { id: string; status: string } | null;
}

export async function createCheckoutSession(env: Env, origin: string): Promise<CheckoutSession> {
  return stripe<CheckoutSession>(env, "POST", "/checkout/sessions", {
    mode: "subscription",
    "line_items[0][price]": env.STRIPE_PRICE_BASE,
    "line_items[0][quantity]": "1",
    "line_items[1][price]": env.STRIPE_PRICE_LOCAL,
    "line_items[2][price]": env.STRIPE_PRICE_INSTANT,
    success_url: `${origin}/activated?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${env.SITE_URL}pricing.html`,
    "subscription_data[metadata][product]": "relay-hosted",
    "subscription_data[description]": "Relay Hosted",
  });
}

export async function retrieveCheckoutSession(env: Env, id: string): Promise<CheckoutSession> {
  return stripe<CheckoutSession>(env, "GET", `/checkout/sessions/${encodeURIComponent(id)}?expand[]=subscription`);
}

export async function createPortalSession(env: Env, customerId: string, returnUrl: string): Promise<{ url: string }> {
  return stripe<{ url: string }>(env, "POST", "/billing_portal/sessions", {
    customer: customerId,
    return_url: returnUrl,
  });
}

/** One usage record. `identifier` makes retries idempotent on Stripe's side. */
export async function reportMeterEvent(env: Env, eventName: string, customerId: string, value: number, identifier: string): Promise<void> {
  await stripe(env, "POST", "/billing/meter_events", {
    event_name: eventName,
    identifier,
    "payload[stripe_customer_id]": customerId,
    "payload[value]": String(value),
  });
}

/** Verifies a Stripe-Signature header against the raw body. */
export async function verifyWebhook(payload: string, header: string | null, secret: string, toleranceSeconds = 300, now = Date.now()): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(",").map((kv) => kv.split("=") as [string, string]));
  const timestamp = Number(parts.t);
  const signature = parts.v1;
  if (!timestamp || !signature) return false;
  if (Math.abs(now / 1000 - timestamp) > toleranceSeconds) return false;

  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${payload}`));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return timingSafeEqual(expected, signature);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
