export interface Env {
  DB: D1Database;
  METER: DurableObjectNamespace;
  ORG_METER: DurableObjectNamespace;
  SITE_URL: string;
  OPENAI_TEXT_MODEL: string;
  OPENAI_REALTIME_MODEL: string;
  OPENAI_TRANSCRIPTION_MODEL: string;
  MONTHLY_CAP_CENTS: string;
  STRIPE_PRICE_BASE: string;
  STRIPE_PRICE_LOCAL: string;
  STRIPE_PRICE_INSTANT: string;
  STRIPE_METER_LOCAL: string;
  STRIPE_METER_INSTANT: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  OPENAI_API_KEY: string;
  /// 32 bytes, base64: seals org provider keys and IdP secrets at rest.
  ORG_KEK: string;
  /// One-time secret for creating the first org.
  BOOTSTRAP_SECRET: string;
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function problem(status: number, message: string): Response {
  return json({ error: { message } }, status);
}
