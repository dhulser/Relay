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

describe("per-model rates", () => {
  it("prices every model the app can offer", async () => {
    const { MODEL_CENTS_PER_HOUR, KNOWN_MODELS } = await import("../src/pricing");
    for (const model of ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
                         "claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]) {
      expect(KNOWN_MODELS).toContain(model);
      expect(MODEL_CENTS_PER_HOUR[model]).toBeGreaterThan(0);
    }
  });

  it("charges a bigger model more per minute, which is the whole point", async () => {
    const { localCentsPerMinute } = await import("../src/pricing");
    expect(localCentsPerMinute("claude-opus-5")).toBeGreaterThan(localCentsPerMinute("claude-haiku-4-5"));
    expect(localCentsPerMinute("gpt-5.6-sol")).toBeGreaterThan(localCentsPerMinute("gpt-5.6-luna"));
    // 25x between the cheapest and dearest is why a flat rate could not stay honest.
    expect(localCentsPerMinute("gpt-5.6-sol") / localCentsPerMinute("gpt-5.6-luna")).toBeGreaterThan(20);
  });

  it("falls back to the flat rate for a model it does not know", async () => {
    const { localCentsPerMinute, LOCAL_CENTS_PER_MINUTE } = await import("../src/pricing");
    expect(localCentsPerMinute("something-else")).toBe(LOCAL_CENTS_PER_MINUTE);
  });
});
