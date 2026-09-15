import type { Env } from "./env";
import { INSTANT_CENTS_PER_MINUTE, LOCAL_CENTS_PER_MINUTE, minuteKey, monthKey } from "./pricing";

// One Durable Object per org, holding this month's counters for every member.
// The org cap and each member's cap are checked in the same place that
// changes them, so two Macs cannot race past a limit. Every change is also
// rolled into usage_daily in D1 for the console and the CSV export.

interface MemberCounters {
  localMinutes: number;
  /// Money spent on Local mode, accumulated as it happens, because the rate
  /// depends on which model each minute ran.
  localCents?: number;
  instantSeconds: number;
  lastLocalMinute: number;
}
interface MonthRecord { members: Record<string, MemberCounters> }

export interface OrgAllowance {
  allowed: boolean;
  reason?: string;
  memberCents: number;
  orgCents: number;
}

interface Limits { memberCapCents: number; orgCapCents: number }

const RATE_WINDOW_MS = 60_000;
const MAX_TRANSLATIONS_PER_MINUTE = 60;

function cents(c: MemberCounters): number {
  // Counters written before the meter knew about models carry no localCents;
  // fall back to the flat rate for those.
  const local = c.localCents ?? c.localMinutes * LOCAL_CENTS_PER_MINUTE;
  return Math.ceil(local + (c.instantSeconds / 60) * INSTANT_CENTS_PER_MINUTE);
}

export class OrgMeter implements DurableObject {
  private orgId = "";

  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.orgId = url.searchParams.get("org") ?? this.orgId;
    if (!this.orgId) return new Response("org required", { status: 400 });

    const body = request.method === "POST"
      ? ((await request.json()) as { member: string; seconds?: number; centsPerMinute?: number } & Limits)
      : null;
    switch (`${request.method} ${url.pathname}`) {
      case "POST /local":
        return Response.json(await this.recordLocal(body!.member, body!, body!.centsPerMinute ?? LOCAL_CENTS_PER_MINUTE));
      case "POST /instant":
        return Response.json(await this.recordInstant(body!.member, body!.seconds ?? 0, body!));
      case "POST /allowance":
        return Response.json(await this.allowance(body!.member, await this.month(), body!));
      case "GET /usage": {
        const member = url.searchParams.get("member") ?? "";
        const record = await this.month();
        const c = record.members[member] ?? { localMinutes: 0, instantSeconds: 0, lastLocalMinute: 0 };
        return Response.json({ month: monthKey(), localMinutes: c.localMinutes, instantSeconds: c.instantSeconds, estimatedCents: cents(c) });
      }
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private async month(): Promise<MonthRecord> {
    return (await this.state.storage.get<MonthRecord>(`usage:${monthKey()}`)) ?? { members: {} };
  }

  private async save(record: MonthRecord): Promise<void> {
    await this.state.storage.put(`usage:${monthKey()}`, record);
  }

  private counters(record: MonthRecord, member: string): MemberCounters {
    return (record.members[member] ??= { localMinutes: 0, instantSeconds: 0, lastLocalMinute: 0 });
  }

  private async allowance(member: string, record: MonthRecord, limits: Limits): Promise<OrgAllowance> {
    const mine = cents(this.counters(record, member));
    const everyone = Object.values(record.members).reduce((sum, c) => sum + cents(c), 0);
    if (limits.memberCapCents > 0 && mine >= limits.memberCapCents) {
      return { allowed: false, memberCents: mine, orgCents: everyone,
        reason: `You have reached this month's limit of $${(limits.memberCapCents / 100).toFixed(0)} for your account. Ask your Relay admin to raise it.` };
    }
    if (limits.orgCapCents > 0 && everyone >= limits.orgCapCents) {
      return { allowed: false, memberCents: mine, orgCents: everyone,
        reason: `Your company has reached this month's Relay limit. Ask your Relay admin to raise it.` };
    }
    return { allowed: true, memberCents: mine, orgCents: everyone };
  }

  private async recordLocal(member: string, limits: Limits, centsPerMinute: number): Promise<OrgAllowance> {
    if (!(await this.withinRateLimit(member))) {
      const current = await this.allowance(member, await this.month(), limits);
      return { ...current, allowed: false, reason: "Too many translations in a minute." };
    }
    const record = await this.month();
    const check = await this.allowance(member, record, limits);
    if (!check.allowed) return check;

    const c = this.counters(record, member);
    const minute = minuteKey();
    if (minute !== c.lastLocalMinute) {
      c.lastLocalMinute = minute;
      c.localMinutes += 1;
      c.localCents = (c.localCents ?? 0) + centsPerMinute;
      await this.save(record);
      await this.rollup(member, 1, 0);
    }
    return this.allowance(member, record, limits);
  }

  private async recordInstant(member: string, seconds: number, limits: Limits): Promise<OrgAllowance> {
    const record = await this.month();
    const c = this.counters(record, member);
    const add = Math.max(0, Math.floor(seconds));
    c.instantSeconds += add;
    await this.save(record);
    if (add > 0) await this.rollup(member, 0, add);
    return this.allowance(member, record, limits);
  }

  private async rollup(member: string, localMinutes: number, instantSeconds: number): Promise<void> {
    const day = new Date().toISOString().slice(0, 10);
    try {
      await this.env.DB.prepare(`
        INSERT INTO usage_daily (org_id, member_id, day, local_minutes, instant_seconds) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(org_id, member_id, day) DO UPDATE SET
          local_minutes = local_minutes + excluded.local_minutes,
          instant_seconds = instant_seconds + excluded.instant_seconds`,
      ).bind(this.orgId, member, day, localMinutes, instantSeconds).run();
    } catch (error) {
      console.error("usage rollup failed", String(error));
    }
  }

  private async withinRateLimit(member: string): Promise<boolean> {
    const now = Date.now();
    const key = `rate:${member}`;
    const recent = ((await this.state.storage.get<number[]>(key)) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
    if (recent.length >= MAX_TRANSLATIONS_PER_MINUTE) return false;
    recent.push(now);
    await this.state.storage.put(key, recent);
    return true;
  }
}

export function orgMeterFor(env: Env, orgId: string, memberId: string, limits: Limits) {
  const stub = env.ORG_METER.get(env.ORG_METER.idFromName(orgId));
  const call = async <T>(method: string, path: string, body?: unknown): Promise<T> => {
    const url = new URL(`https://meter/${path}`);
    url.searchParams.set("org", orgId);
    url.searchParams.set("member", memberId);
    const response = await stub.fetch(url.toString(), {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
    return response.json() as Promise<T>;
  };
  const payload = { member: memberId, ...limits };
  return {
    local: (centsPerMinute?: number) => call<OrgAllowance>("POST", "local", { ...payload, centsPerMinute }),
    instant: (seconds: number) => call<OrgAllowance>("POST", "instant", { ...payload, seconds }),
    allowance: () => call<OrgAllowance>("POST", "allowance", payload),
    usage: () => call<{ month: string; localMinutes: number; instantSeconds: number; estimatedCents: number }>("GET", "usage"),
  };
}
