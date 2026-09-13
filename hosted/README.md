# Relay Hosted

The backend for people who would rather not manage a key. One Cloudflare
Worker: Stripe signup and billing, a translate proxy, an Instant-mode
WebSocket proxy, and a Durable Object per customer that meters minutes and
enforces a monthly cap.

Live at `https://relay-api.onethreefive.workers.dev`.

## How it fits together

```
Relay.app ──POST /v1/translate {text,target}──▶ Worker ──▶ OpenAI chat completions (Luna)
          ◀──── OpenAI's SSE stream, unchanged ─┘
Relay.app ──WS  /v1/realtime?target=en ────────▶ Worker ──WS──▶ OpenAI Realtime translations
                                                   │
                                        CustomerMeter (Durable Object)
                                        minutes → Stripe meter events
```

- **Local mode** bills each calendar minute in which at least one utterance was
  translated. A quiet minute costs nothing. The server owns the prompt and the
  model, so the proxy cannot be used as a general model.
- **Instant mode** bills the minutes the socket is open. The Worker settles
  every 60 s and closes the socket the minute the cap is reached (code 4402).
- **The cap** (`MONTHLY_CAP_CENTS`, $50) includes the $2 base. Over it, both
  endpoints return 402 with a plain-language reason the app shows.
- **Accounts** are Stripe customers. Checkout success mints a bearer token
  (`rly_…`, 32 random bytes, only the hash is stored) and hands it to the app
  via `relay://activate?token=…`, with the code shown as a fallback.

## One-time setup

1. **Stripe**. In the Stripe dashboard create an account, then with its
   *secret* key in the environment (never in a file):

   ```bash
   STRIPE_SECRET_KEY=sk_test_… ./scripts/stripe-setup.sh
   ```

   It creates the product, the $2 base price, two meters and two metered
   prices, and prints three price ids. Put them in `wrangler.jsonc` under
   `vars`. Run it again with the live key when you switch modes.

2. **Secrets** (each prompts for the value; nothing lands in a file):

   ```bash
   npx wrangler secret put STRIPE_SECRET_KEY
   npx wrangler secret put OPENAI_API_KEY
   ```

3. **Webhook**. Stripe dashboard → Developers → Webhooks → add endpoint
   `https://relay-api.onethreefive.workers.dev/webhooks/stripe` for
   `customer.subscription.updated` and `customer.subscription.deleted`, then:

   ```bash
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```

4. **Deploy**: `npx wrangler deploy`.

## Day to day

```bash
npm test                          # pure logic: pricing, prompt, webhook signatures
npx wrangler dev                  # local, with a local D1 and Durable Object
npx wrangler tail                 # live logs from production
npx wrangler d1 execute relay --remote --command "SELECT id, status, created_at FROM customers"
```

## Endpoints

| Route | Auth | What |
|---|---|---|
| `POST /v1/checkout` | none | Stripe Checkout link |
| `GET /activated?session_id=` | none | success page; mints the token once |
| `POST /webhooks/stripe` | signature | keeps subscription status current |
| `POST /v1/translate` | bearer | one utterance → SSE |
| `GET /v1/realtime` | bearer | WebSocket proxy |
| `GET /v1/me` | bearer | status and this month's usage |
| `POST /v1/portal` | bearer | Stripe billing portal link |
| `POST /v1/tokens` | bearer | a token for another Mac |
| `POST /v1/signout` | bearer | revokes this token |
