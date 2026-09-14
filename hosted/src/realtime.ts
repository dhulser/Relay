import type { Env } from "./env";
import type { Principal } from "./auth";
import { problem } from "./env";
import { meterFor } from "./meter";
import { orgById, orgKeys } from "./orgs";
import { orgMeterFor } from "./orgmeter";
import { LANGUAGE_CODES } from "./prompt";

// GET /v1/realtime — upgrades to a WebSocket and pipes it to OpenAI's
// Realtime translations endpoint with the right key: Relay's for an
// individual, the company's for a member. Connection time is metered.

const TICK_MS = 60_000;

interface Meter { allowance(): Promise<{ allowed: boolean; reason?: string }>; instant(seconds: number): Promise<{ allowed: boolean; reason?: string }> }

async function resolve(env: Env, who: Principal): Promise<{ ok: true; key: string; meter: Meter } | { ok: false; status: number; message: string }> {
  if (who.kind === "customer") return { ok: true, key: env.OPENAI_API_KEY, meter: meterFor(env, who.customerId) };
  const org = await orgById(env, who.orgId);
  if (!org) return { ok: false, status: 403, message: "Your company's Relay account no longer exists." };
  if (!org.policy.allowInstant) return { ok: false, status: 403, message: `${org.name} has turned Instant mode off. Use Local mode.` };
  const keys = await orgKeys(env, who.orgId);
  if (!keys.openai) return { ok: false, status: 503, message: `${org.name} has not added an OpenAI key to Relay, which Instant mode needs.` };
  return { ok: true, key: keys.openai, meter: orgMeterFor(env, who.orgId, who.memberId, { memberCapCents: org.memberCapCents, orgCapCents: org.orgCapCents }) };
}

export async function realtime(request: Request, env: Env, who: Principal): Promise<Response> {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return problem(426, "This endpoint is a WebSocket.");

  const url = new URL(request.url);
  const source = url.searchParams.get("source");
  const target = url.searchParams.get("target");
  if (source && !LANGUAGE_CODES.has(source)) return problem(400, "Unknown source language.");
  if (target && !LANGUAGE_CODES.has(target)) return problem(400, "Unknown target language.");

  const route = await resolve(env, who);
  if (!route.ok) return problem(route.status, route.message);
  const { key, meter } = route;

  const allowance = await meter.allowance();
  if (!allowance.allowed) return problem(402, allowance.reason ?? "Not allowed right now.");

  const upstreamResponse = await fetch(
    `https://api.openai.com/v1/realtime/translations?model=${encodeURIComponent(env.OPENAI_REALTIME_MODEL)}`,
    { headers: { upgrade: "websocket", authorization: `Bearer ${key}` } },
  );
  const upstream = upstreamResponse.webSocket;
  if (!upstream) {
    console.error("openai realtime", upstreamResponse.status, await upstreamResponse.text().catch(() => ""));
    return problem(502, "The translation service did not answer.");
  }
  upstream.accept();

  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  server.accept();

  let billedUntil = Date.now();
  let closed = false;

  const settle = async () => {
    const now = Date.now();
    const seconds = Math.floor((now - billedUntil) / 1000);
    billedUntil = now;
    return seconds > 0 ? meter.instant(seconds) : null;
  };

  const shutdown = async (code: number, reason: string) => {
    if (closed) return;
    closed = true;
    clearInterval(ticker);
    await settle().catch(() => null);
    try { upstream.close(1000, "session ended"); } catch { /* already closed */ }
    try { server.close(code, reason); } catch { /* already closed */ }
  };

  const ticker = setInterval(async () => {
    const result = await settle().catch(() => null);
    if (result && !result.allowed) await shutdown(4402, result.reason ?? "Limit reached.");
  }, TICK_MS);

  server.addEventListener("message", (event) => { try { upstream.send(event.data); } catch { /* closing */ } });
  upstream.addEventListener("message", (event) => { try { server.send(event.data); } catch { /* closing */ } });
  server.addEventListener("close", () => void shutdown(1000, "client closed"));
  upstream.addEventListener("close", (event) => void shutdown(event.code || 1011, event.reason || "upstream closed"));
  server.addEventListener("error", () => void shutdown(1011, "client error"));
  upstream.addEventListener("error", () => void shutdown(1011, "upstream error"));

  return new Response(null, { status: 101, webSocket: client });
}
