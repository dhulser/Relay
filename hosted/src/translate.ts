import type { Env } from "./env";
import type { Principal } from "./auth";
import { problem } from "./env";
import { meterFor } from "./meter";
import { orgById, orgKeys } from "./orgs";
import { orgMeterFor } from "./orgmeter";
import { instructions, LANGUAGES, MAX_UTTERANCE_CHARS } from "./prompt";
import { KNOWN_MODELS, localCentsPerMinute } from "./pricing";

interface TranslateRequest { text?: unknown; target?: unknown; source?: unknown; model?: unknown }

/** Which provider and key a principal's Local mode runs on. */
export async function resolveLocal(env: Env, who: Principal, requested?: string): Promise<
  | { ok: true; provider: "openai" | "anthropic"; key: string; model: string; record: () => Promise<{ allowed: boolean; reason?: string }> }
  | { ok: false; status: number; message: string }
> {
  if (who.kind === "customer") {
    return {
      ok: true, provider: "openai", key: env.OPENAI_API_KEY, model: env.OPENAI_TEXT_MODEL,
      record: () => meterFor(env, who.customerId).local(),
    };
  }
  const org = await orgById(env, who.orgId);
  if (!org) return { ok: false, status: 403, message: "Your company's Relay account no longer exists." };

  // A member may ask for a different model only when the admin allows it, and
  // only one this proxy knows the price of.
  let model = org.localModel;
  if (requested && requested !== org.localModel) {
    if (!org.allowModelChoice) {
      return { ok: false, status: 403, message: `${org.name} runs Relay on one model, chosen by whoever administers it.` };
    }
    if (!KNOWN_MODELS.includes(requested)) {
      return { ok: false, status: 400, message: "Relay does not know that model." };
    }
    model = requested;
  }

  const keys = await orgKeys(env, who.orgId);
  const provider: "openai" | "anthropic" = model.startsWith("claude") ? "anthropic" : "openai";
  const key = provider === "anthropic" ? keys.anthropic : keys.openai;
  if (!key) return { ok: false, status: 503, message: `${org.name} has not added ${provider === "anthropic" ? "an Anthropic" : "an OpenAI"} key to Relay yet.` };

  const meter = orgMeterFor(env, who.orgId, who.memberId, { memberCapCents: org.memberCapCents, orgCapCents: org.orgCapCents });
  const rate = localCentsPerMinute(model);
  return { ok: true, provider, key, model, record: () => meter.local(rate) };
}

/** POST /v1/translate — one utterance in, an OpenAI-shaped SSE stream out.
 *  The app reads that one format whichever provider is behind it. */
export async function translate(request: Request, env: Env, who: Principal): Promise<Response> {
  let body: TranslateRequest;
  try { body = (await request.json()) as TranslateRequest; } catch { return problem(400, "Body must be JSON."); }

  const text = typeof body.text === "string" ? body.text.trim() : "";
  const target = typeof body.target === "string" ? body.target : "";
  const source = typeof body.source === "string" && body.source ? body.source : undefined;
  if (!text) return problem(400, "Nothing to translate.");
  if (text.length > MAX_UTTERANCE_CHARS) return problem(413, "That is longer than one spoken phrase.");
  if (!LANGUAGES.has(target)) return problem(400, "Unknown target language.");
  if (source && !LANGUAGES.has(source)) return problem(400, "Unknown source language.");

  const route = await resolveLocal(env, who, typeof body.model === "string" ? body.model : undefined);
  if (!route.ok) return problem(route.status, route.message);

  const allowance = await route.record();
  if (!allowance.allowed) return problem(402, allowance.reason ?? "Not allowed right now.");

  const system = instructions(target, source);
  const upstream = route.provider === "anthropic"
    ? await anthropic(route.key, route.model, system, text)
    : await openai(route.key, route.model, system, text);

  if (!upstream.ok || !upstream.body) {
    console.error(route.provider, upstream.status, await upstream.text().catch(() => ""));
    return problem(502, "The translation service did not answer.");
  }

  const stream = route.provider === "anthropic" ? upstream.body.pipeThrough(anthropicToOpenAI()) : upstream.body;
  return new Response(stream, {
    status: 200,
    headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store" },
  });
}

function openai(key: string, model: string, system: string, text: string): Promise<Response> {
  return fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      model, stream: true, max_completion_tokens: 400,
      messages: [{ role: "system", content: system }, { role: "user", content: text }],
    }),
  });
}

function anthropic(key: string, model: string, system: string, text: string): Promise<Response> {
  return fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model, stream: true, max_tokens: 400, system,
      messages: [{ role: "user", content: text }],
      // Sonnet 5 and Opus 5 think by default; a one-line translation gains nothing from it.
      ...(model.includes("haiku") ? {} : { thinking: { type: "disabled" } }),
    }),
  });
}

/** Rewrites Anthropic's SSE into OpenAI chat-completion chunks, so the app
 *  needs one parser. Only text deltas matter; everything else is dropped. */
export function anthropicToOpenAI(): TransformStream<Uint8Array, Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let pending = "";
  const chunk = (content: string) => encoder.encode(`data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`);
  return new TransformStream({
    transform(bytes, controller) {
      pending += decoder.decode(bytes, { stream: true });
      const lines = pending.split("\n");
      pending = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        try {
          const event = JSON.parse(line.slice(6)) as { type: string; delta?: { type?: string; text?: string } };
          if (event.type === "content_block_delta" && event.delta?.text) controller.enqueue(chunk(event.delta.text));
        } catch { /* keep-alives and partial lines */ }
      }
    },
    flush(controller) {
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
    },
  });
}
