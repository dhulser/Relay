import type { Env } from "./env";
import type { Principal } from "./auth";
import { problem } from "./env";
import { meterFor } from "./meter";
import { orgById, orgKeys } from "./orgs";
import { orgMeterFor } from "./orgmeter";
import { SPEAK_COST_CENTS_PER_MINUTE } from "./pricing";

/** The voices the app offers. Anything else is refused, so the proxy cannot
 *  be steered onto a voice nobody chose. */
export const VOICES = new Set(["nova", "cedar"]);
/** A translation of one spoken phrase; this is generous. */
export const MAX_SPEAK_CHARS = 1_000;
/** Raw 24 kHz mono Int16: what one second of speech weighs. */
export const PCM_BYTES_PER_SECOND = 24_000 * 2;

const INSTRUCTIONS = "You are interpreting for someone on a call. Speak naturally and clearly at a conversational pace, warm and neutral, no theatrical emotion.";

export interface SpeakRequest { text: string; voice: string }

/** Validates the body, or says what is wrong with it. */
export function parseSpeakRequest(body: unknown): { ok: true; request: SpeakRequest } | { ok: false; status: number; message: string } {
  const b = (body ?? {}) as { text?: unknown; voice?: unknown };
  const text = typeof b.text === "string" ? b.text.trim() : "";
  const voice = typeof b.voice === "string" ? b.voice : "";
  if (!text) return { ok: false, status: 400, message: "Nothing to say." };
  if (text.length > MAX_SPEAK_CHARS) return { ok: false, status: 413, message: "That is longer than one spoken phrase." };
  if (!VOICES.has(voice)) return { ok: false, status: 400, message: "Relay does not know that voice." };
  return { ok: true, request: { text, voice } };
}

/** Counts the bytes of a stream as they pass, and reports once at the end. */
export function counting(onDone: (bytes: number) => void): TransformStream<Uint8Array, Uint8Array> {
  let bytes = 0;
  return new TransformStream({
    transform(chunk, controller) { bytes += chunk.byteLength; controller.enqueue(chunk); },
    flush() { onDone(bytes); },
  });
}

/** POST /v1/speak — one sentence in, raw PCM out, streamed as it is generated.
 *  Metered by the seconds of audio actually returned, after the fact, since
 *  nobody knows how long a sentence will take to say before it is said. */
export async function speak(request: Request, env: Env, who: Principal, ctx: ExecutionContext): Promise<Response> {
  let body: unknown;
  try { body = await request.json(); } catch { return problem(400, "Body must be JSON."); }
  const parsed = parseSpeakRequest(body);
  if (!parsed.ok) return problem(parsed.status, parsed.message);

  let key: string;
  let record: (seconds: number) => Promise<unknown>;
  let allowance: () => Promise<{ allowed: boolean; reason?: string }>;
  if (who.kind === "customer") {
    key = env.OPENAI_API_KEY;
    const meter = meterFor(env, who.customerId);
    allowance = () => meter.allowance();
    record = (seconds) => meter.speak(seconds);
  } else {
    const org = await orgById(env, who.orgId);
    if (!org) return problem(403, "Your company's Relay account no longer exists.");
    if (!org.policy.allowSpeak) return problem(403, `${org.name} has turned Speak off.`);
    const keys = await orgKeys(env, who.orgId);
    if (!keys.openai) return problem(503, `${org.name} has not added an OpenAI key to Relay yet, and the voices need one.`);
    key = keys.openai;
    const meter = orgMeterFor(env, who.orgId, who.memberId, { memberCapCents: org.memberCapCents, orgCapCents: org.orgCapCents });
    allowance = () => meter.allowance();
    record = (seconds) => meter.speak(seconds, SPEAK_COST_CENTS_PER_MINUTE);
  }

  const check = await allowance();
  if (!check.allowed) return problem(402, check.reason ?? "Not allowed right now.");

  const upstream = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: env.OPENAI_SPEECH_MODEL, voice: parsed.request.voice, input: parsed.request.text,
      instructions: INSTRUCTIONS, response_format: "pcm",
    }),
  });
  if (!upstream.ok || !upstream.body) {
    console.error("speech", upstream.status, await upstream.text().catch(() => ""));
    return problem(502, "The voice service did not answer.");
  }

  const metered = upstream.body.pipeThrough(counting((bytes) => {
    const seconds = bytes / PCM_BYTES_PER_SECOND;
    if (seconds > 0) ctx.waitUntil(record(seconds).catch((error) => console.error("speak meter", String(error))));
  }));
  return new Response(metered, {
    status: 200,
    headers: { "content-type": "audio/pcm", "x-relay-sample-rate": "24000", "cache-control": "no-store" },
  });
}
