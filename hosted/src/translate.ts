import type { Env } from "./env";
import type { Principal } from "./auth";
import { problem } from "./env";
import { meterFor } from "./meter";
import { instructions, LANGUAGES, MAX_UTTERANCE_CHARS } from "./prompt";

interface TranslateRequest {
  text?: unknown;
  target?: unknown;
  source?: unknown;
}

/** POST /v1/translate — one utterance in, OpenAI's SSE stream straight back
 *  out. The app already reads that format for bring-your-own-key, so hosted
 *  mode needs no new parser. The server owns the prompt and the model. */
export async function translate(request: Request, env: Env, who: Principal): Promise<Response> {
  let body: TranslateRequest;
  try {
    body = (await request.json()) as TranslateRequest;
  } catch {
    return problem(400, "Body must be JSON.");
  }

  const text = typeof body.text === "string" ? body.text.trim() : "";
  const target = typeof body.target === "string" ? body.target : "";
  const source = typeof body.source === "string" && body.source ? body.source : undefined;

  if (!text) return problem(400, "Nothing to translate.");
  if (text.length > MAX_UTTERANCE_CHARS) return problem(413, "That is longer than one spoken phrase.");
  if (!LANGUAGES.has(target)) return problem(400, "Unknown target language.");
  if (source && !LANGUAGES.has(source)) return problem(400, "Unknown source language.");

  const allowance = await meterFor(env, who.customerId).local();
  if (!allowance.allowed) return problem(402, allowance.reason ?? "Not allowed right now.");

  const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: env.OPENAI_TEXT_MODEL,
      stream: true,
      max_completion_tokens: 400,
      messages: [
        { role: "system", content: instructions(target, source) },
        { role: "user", content: text },
      ],
    }),
  });

  if (!upstream.ok || !upstream.body) {
    console.error("openai", upstream.status, await upstream.text().catch(() => ""));
    return problem(502, "The translation service did not answer.");
  }

  return new Response(upstream.body, {
    status: 200,
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-store",
      "x-relay-estimated-cents": String(allowance.estimatedCents),
    },
  });
}
