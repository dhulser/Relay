import type { Env } from "./env";
import type { Principal } from "./auth";
import { problem } from "./env";
import { meterFor } from "./meter";
import { LANGUAGE_CODES } from "./prompt";

// GET /v1/realtime — upgrades to a WebSocket and pipes it to OpenAI's
// Realtime translations endpoint with our key. The app speaks the same
// protocol it uses with its own key; only the address and the credential
// differ. Connection time is metered in minutes while the socket is open.

const TICK_MS = 60_000;

export async function realtime(request: Request, env: Env, who: Principal): Promise<Response> {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return problem(426, "This endpoint is a WebSocket.");
  }

  const url = new URL(request.url);
  const source = url.searchParams.get("source");
  const target = url.searchParams.get("target");
  if (source && !LANGUAGE_CODES.has(source)) return problem(400, "Unknown source language.");
  if (target && !LANGUAGE_CODES.has(target)) return problem(400, "Unknown target language.");

  const meter = meterFor(env, who.customerId);
  const allowance = await meter.allowance();
  if (!allowance.allowed) return problem(402, allowance.reason ?? "Not allowed right now.");

  const upstreamResponse = await fetch(
    `https://api.openai.com/v1/realtime/translations?model=${encodeURIComponent(env.OPENAI_REALTIME_MODEL)}`,
    { headers: { upgrade: "websocket", authorization: `Bearer ${env.OPENAI_API_KEY}` } },
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

  const openedAt = Date.now();
  let billedUntil = openedAt;
  let closed = false;

  const settle = async () => {
    const now = Date.now();
    const seconds = Math.floor((now - billedUntil) / 1000);
    billedUntil = now;
    if (seconds > 0) return meter.instant(seconds);
    return null;
  };

  const shutdown = async (code: number, reason: string) => {
    if (closed) return;
    closed = true;
    clearInterval(ticker);
    await settle().catch(() => null);
    try { upstream.close(1000, "session ended"); } catch { /* already closed */ }
    try { server.close(code, reason); } catch { /* already closed */ }
  };

  // Bill as we go, and stop the session the minute the cap is reached.
  const ticker = setInterval(async () => {
    const result = await settle().catch(() => null);
    if (result && !result.allowed) await shutdown(4402, result.reason ?? "Spending cap reached.");
  }, TICK_MS);

  server.addEventListener("message", (event) => {
    try { upstream.send(event.data); } catch { /* upstream gone; close handler follows */ }
  });
  upstream.addEventListener("message", (event) => {
    try { server.send(event.data); } catch { /* client gone */ }
  });
  server.addEventListener("close", () => void shutdown(1000, "client closed"));
  upstream.addEventListener("close", (event) => void shutdown(event.code || 1011, event.reason || "upstream closed"));
  server.addEventListener("error", () => void shutdown(1011, "client error"));
  upstream.addEventListener("error", () => void shutdown(1011, "upstream error"));

  return new Response(null, { status: 101, webSocket: client });
}
