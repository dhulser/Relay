import { describe, expect, it } from "vitest";
import { estimatedCents, minuteKey, monthKey, STRIPE_UNIT_AMOUNT_DECIMAL } from "../src/pricing";

describe("pricing", () => {
  it("charges the base fee with nothing used", () => {
    expect(estimatedCents({ localMinutes: 0, instantSeconds: 0 })).toBe(200);
  });

  it("matches the pricing page: an hour local is 40 cents, an hour instant is $3.50", () => {
    expect(estimatedCents({ localMinutes: 60, instantSeconds: 0 })).toBe(240);
    expect(estimatedCents({ localMinutes: 0, instantSeconds: 3600 })).toBe(550);
  });

  it("rounds a fraction of a cent up, never down", () => {
    expect(estimatedCents({ localMinutes: 1, instantSeconds: 0 })).toBe(201);
  });

  it("uses the same unit prices Stripe is told", () => {
    expect(STRIPE_UNIT_AMOUNT_DECIMAL.local).toBe("0.6667");
    expect(STRIPE_UNIT_AMOUNT_DECIMAL.instant).toBe("5.8333");
  });

  it("buckets by UTC month and calendar minute", () => {
    const t = new Date(Date.UTC(2026, 8, 13, 23, 59, 30));
    expect(monthKey(t)).toBe("2026-09");
    expect(minuteKey(t)).toBe(Math.floor(t.getTime() / 60000));
  });
});
