// The numbers on the pricing page, in cents. Everything that turns minutes
// into money lives here so the site, the app and the meter cannot disagree.

export const BASE_CENTS_PER_MONTH = 200;
export const LOCAL_CENTS_PER_HOUR = 40;
export const INSTANT_CENTS_PER_HOUR = 350;

export const LOCAL_CENTS_PER_MINUTE = LOCAL_CENTS_PER_HOUR / 60;
export const INSTANT_CENTS_PER_MINUTE = INSTANT_CENTS_PER_HOUR / 60;

/** Unit prices for Stripe's metered prices, as the decimal-cents strings it wants. */
export const STRIPE_UNIT_AMOUNT_DECIMAL = {
  local: LOCAL_CENTS_PER_MINUTE.toFixed(4),     // "0.6667"
  instant: INSTANT_CENTS_PER_MINUTE.toFixed(4), // "5.8333"
};

export interface MonthUsage {
  localMinutes: number;
  instantSeconds: number;
}

/** What the month has cost so far, base fee included, rounded up to a cent. */
export function estimatedCents(usage: MonthUsage): number {
  const instantMinutes = usage.instantSeconds / 60;
  const raw = BASE_CENTS_PER_MONTH
    + usage.localMinutes * LOCAL_CENTS_PER_MINUTE
    + instantMinutes * INSTANT_CENTS_PER_MINUTE;
  return Math.ceil(raw);
}

/** "2026-09", in UTC, which is also how Stripe's calendar-month meters bucket. */
export function monthKey(date = new Date()): string {
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

/** Local minutes are billed per calendar minute in which something was translated. */
export function minuteKey(date = new Date()): number {
  return Math.floor(date.getTime() / 60_000);
}
