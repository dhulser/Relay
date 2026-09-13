-- Customers are Stripe customers; Stripe is the account system.
CREATE TABLE customers (
  id TEXT PRIMARY KEY,            -- Stripe customer id (cus_…)
  subscription_id TEXT,
  status TEXT NOT NULL,           -- Stripe subscription status
  email TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Access tokens the app holds. Only the hash is stored.
CREATE TABLE tokens (
  hash TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL REFERENCES customers(id),
  created_at INTEGER NOT NULL,
  last_used_at INTEGER
);
CREATE INDEX tokens_customer ON tokens(customer_id);

-- A checkout session mints exactly one token, however many times the
-- success page is loaded.
CREATE TABLE checkout_claims (
  session_id TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL,
  claimed_at INTEGER NOT NULL
);
