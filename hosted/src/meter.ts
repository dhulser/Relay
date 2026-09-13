import type { Env } from "./env";
import { reportMeterEvent } from "./stripe";
import { estimatedCents, minuteKey, monthKey, type MonthUsage } from "./pricing";

// One Durable Object per customer. It is the single place that knows how much
// of the month has been used, so a cap check and the usage it changes can
// never race. Usage is reported to Stripe as it happens, idempotently; if
// Stripe is unreachable the report is queued and retried from an alarm.

interface MonthRecord extends MonthUsage {
  lastLocalMinute: number;       // minuteKey of the last billed local minute
  reportedInstantMinutes: number; // whole minutes already sent to Stripe
}

interface Pending {
  eventName: string;
  value: number;
  identifier: string;
}

export interface Allowance {
  allowed: boolean;
  reason?: string;
  estimatedCents: number;
  capCents: number;
}

const RATE_WINDOW_MS = 60_000;
const MAX_TRANSLATIONS_PER_MINUTE = 60;

export class CustomerMeter implements DurableObject {
  private customerId = "";

  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.customerId = url.searchParams.get("customer") ?? this.customerId;
    if (!this.customerId) return new Response("customer required", { status: 400 });

    switch (`${request.method} ${url.pathname}`) {
      case "POST /local":
        return Response.json(await this.recordLocal());
      case "POST /instant": {
        const { seconds } = (await request.json()) as { seconds: number };
        return Response.json(await this.recordInstant(seconds));
      }
      case "GET /allowance":
        return Response.json(await this.allowance());
      case "GET /usage":
        return Response.json(await this.usage());
      default:
        return new Response("not found", { status: 404 });
    }
  }

  // ---- reads

  private async month(): Promise<MonthRecord> {
    const key = `usage:${monthKey()}`;
    return (await this.state.storage.get<MonthRecord>(key))
      ?? { localMinutes: 0, instantSeconds: 0, lastLocalMinute: 0, reportedInstantMinutes: 0 };
  }

  private async save(record: MonthRecord): Promise<void> {
    await this.state.storage.put(`usage:${monthKey()}`, record);
  }

  private capCents(): number {
    return Number(this.env.MONTHLY_CAP_CENTS) || 5000;
  }

  private async allowance(record?: MonthRecord): Promise<Allowance> {
    const usage = record ?? (await this.month());
    const estimate = estimatedCents(usage);
    const cap = this.capCents();
    if (estimate >= cap) {
      return {
        allowed: false,
        estimatedCents: estimate,
        capCents: cap,
        reason: `This month has reached its $${(cap / 100).toFixed(0)} spending cap. It resets on the 1st.`,
      };
    }
    return { allowed: true, estimatedCents: estimate, capCents: cap };
  }

  async usage(): Promise<MonthUsage & { month: string; estimatedCents: number; capCents: number }> {
    const record = await this.month();
    return {
      month: monthKey(),
      localMinutes: record.localMinutes,
      instantSeconds: record.instantSeconds,
      estimatedCents: estimatedCents(record),
      capCents: this.capCents(),
    };
  }

  // ---- writes

  /** One translation request. Bills the calendar minute the first time it is used. */
  private async recordLocal(): Promise<Allowance> {
    if (!(await this.withinRateLimit())) {
      const current = await this.allowance();
      return { ...current, allowed: false, reason: "Too many translations in a minute." };
    }

    const record = await this.month();
    const check = await this.allowance(record);
    if (!check.allowed) return check;

    const minute = minuteKey();
    if (minute !== record.lastLocalMinute) {
      record.lastLocalMinute = minute;
      record.localMinutes += 1;
      await this.save(record);
      await this.report(this.env.STRIPE_METER_LOCAL, 1, `${this.customerId}-local-${minute}`);
    }
    return this.allowance(record);
  }

  /** Seconds of an Instant-mode socket being open. Whole minutes go to Stripe. */
  private async recordInstant(seconds: number): Promise<Allowance> {
    const record = await this.month();
    record.instantSeconds += Math.max(0, Math.floor(seconds));

    const wholeMinutes = Math.floor(record.instantSeconds / 60);
    const unreported = wholeMinutes - record.reportedInstantMinutes;
    if (unreported > 0) {
      record.reportedInstantMinutes = wholeMinutes;
      await this.save(record);
      await this.report(this.env.STRIPE_METER_INSTANT, unreported, `${this.customerId}-instant-${monthKey()}-${wholeMinutes}`);
    } else {
      await this.save(record);
    }
    return this.allowance(record);
  }

  private async withinRateLimit(): Promise<boolean> {
    const now = Date.now();
    const recent = ((await this.state.storage.get<number[]>("rate")) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
    if (recent.length >= MAX_TRANSLATIONS_PER_MINUTE) return false;
    recent.push(now);
    await this.state.storage.put("rate", recent);
    return true;
  }

  // ---- Stripe reporting, with a retry queue

  private async report(eventName: string, value: number, identifier: string): Promise<void> {
    if (!this.env.STRIPE_SECRET_KEY) return; // local dev without Stripe
    try {
      await reportMeterEvent(this.env, eventName, this.customerId, value, identifier);
    } catch (error) {
      console.error("meter report failed, queued", identifier, String(error));
      const pending = (await this.state.storage.get<Pending[]>("pending")) ?? [];
      pending.push({ eventName, value, identifier });
      await this.state.storage.put("pending", pending);
      await this.state.storage.setAlarm(Date.now() + 5 * 60_000);
    }
  }

  async alarm(): Promise<void> {
    const pending = (await this.state.storage.get<Pending[]>("pending")) ?? [];
    const remaining: Pending[] = [];
    for (const item of pending) {
      try {
        await reportMeterEvent(this.env, item.eventName, this.customerId, item.value, item.identifier);
      } catch {
        remaining.push(item);
      }
    }
    await this.state.storage.put("pending", remaining);
    if (remaining.length) await this.state.storage.setAlarm(Date.now() + 15 * 60_000);
  }
}

/** The customer's meter, addressed by their Stripe id. */
export function meterFor(env: Env, customerId: string) {
  const stub = env.METER.get(env.METER.idFromName(customerId));
  const call = async <T>(method: string, path: string, body?: unknown): Promise<T> => {
    const response = await stub.fetch(`https://meter/${path}?customer=${encodeURIComponent(customerId)}`, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
    return response.json() as Promise<T>;
  };
  return {
    local: () => call<Allowance>("POST", "local"),
    instant: (seconds: number) => call<Allowance>("POST", "instant", { seconds }),
    allowance: () => call<Allowance>("GET", "allowance"),
    usage: () => call<MonthUsage & { month: string; estimatedCents: number; capCents: number }>("GET", "usage"),
  };
}
