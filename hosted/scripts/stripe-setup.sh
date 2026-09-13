#!/bin/bash
# One-time Stripe setup for Relay Hosted: the product, the $2/month base
# price, two usage meters, and a metered price on each. Prints the ids to put
# in wrangler.jsonc.
#
#   STRIPE_SECRET_KEY=sk_test_… ./scripts/stripe-setup.sh
#
# Run once against test keys, then once against live keys. Safe to re-run:
# meters are looked up by event name first.
set -euo pipefail
: "${STRIPE_SECRET_KEY:?set STRIPE_SECRET_KEY in the environment (never in a file)}"

api() { curl -fsS -u "$STRIPE_SECRET_KEY:" -H "Stripe-Version: 2025-08-27.basil" "$@"; }
field() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

echo "Product"
PRODUCT=$(api https://api.stripe.com/v1/products -d name="Relay Hosted" \
  -d description="Live translated subtitles on your Mac, with the keys handled for you." | field '["id"]')
echo "  $PRODUCT"

echo "Base price: \$2 a month"
BASE=$(api https://api.stripe.com/v1/prices -d product="$PRODUCT" -d currency=usd \
  -d unit_amount=200 -d "recurring[interval]=month" -d nickname="Relay Hosted base" | field '["id"]')
echo "  $BASE"

meter() {  # name, event_name, display -> meter id (existing or new)
  local existing
  existing=$(api "https://api.stripe.com/v1/billing/meters?status=active&limit=100" \
    | python3 -c 'import sys,json; want=sys.argv[1]; print(next((m["id"] for m in json.load(sys.stdin)["data"] if m["event_name"]==want), ""))' "$1")
  if [ -n "$existing" ]; then echo "$existing"; return; fi
  api https://api.stripe.com/v1/billing/meters -d display_name="$2" -d event_name="$1" \
    -d "default_aggregation[formula]=sum" -d "customer_mapping[event_payload_key]=stripe_customer_id" \
    -d "customer_mapping[type]=by_id" -d "value_settings[event_payload_key]=value" | field '["id"]'
}

echo "Meters"
METER_LOCAL=$(meter relay_local_minutes "Relay Local minutes")
METER_INSTANT=$(meter relay_instant_minutes "Relay Instant minutes")
echo "  $METER_LOCAL  $METER_INSTANT"

echo "Metered prices: 40¢ an hour local, \$3.50 an hour instant, billed per minute"
LOCAL=$(api https://api.stripe.com/v1/prices -d product="$PRODUCT" -d currency=usd \
  -d unit_amount_decimal=0.6667 -d "recurring[interval]=month" -d "recurring[usage_type]=metered" \
  -d "recurring[meter]=$METER_LOCAL" -d nickname="Relay Local minutes" | field '["id"]')
INSTANT=$(api https://api.stripe.com/v1/prices -d product="$PRODUCT" -d currency=usd \
  -d unit_amount_decimal=5.8333 -d "recurring[interval]=month" -d "recurring[usage_type]=metered" \
  -d "recurring[meter]=$METER_INSTANT" -d nickname="Relay Instant minutes" | field '["id"]')
echo "  $LOCAL  $INSTANT"

cat <<OUT

Put these in hosted/wrangler.jsonc under "vars":
  "STRIPE_PRICE_BASE": "$BASE",
  "STRIPE_PRICE_LOCAL": "$LOCAL",
  "STRIPE_PRICE_INSTANT": "$INSTANT",

Then add a webhook endpoint in the Stripe dashboard pointing at
  https://<your-worker>/webhooks/stripe
for the events customer.subscription.updated and customer.subscription.deleted,
and store its signing secret with:  wrangler secret put STRIPE_WEBHOOK_SECRET
OUT
