import { describe, expect, it } from "vitest";
import { counting, parseSpeakRequest, PCM_BYTES_PER_SECOND } from "../src/speak";

describe("speak requests", () => {
  it("accepts a sentence in a known voice", () => {
    const result = parseSpeakRequest({ text: " Gracias por acompañarnos. ", voice: "cedar" });
    expect(result).toEqual({ ok: true, request: { text: "Gracias por acompañarnos.", voice: "cedar" } });
  });

  it("refuses an empty sentence, an unknown voice, and a speech", () => {
    expect(parseSpeakRequest({ text: "", voice: "nova" })).toMatchObject({ ok: false, status: 400 });
    expect(parseSpeakRequest({ text: "Hola", voice: "onyx" })).toMatchObject({ ok: false, status: 400 });
    expect(parseSpeakRequest({ text: "x".repeat(1001), voice: "nova" })).toMatchObject({ ok: false, status: 413 });
    expect(parseSpeakRequest(null)).toMatchObject({ ok: false });
  });

  it("counts the bytes that flow through and reports once at the end", async () => {
    let reported = -1;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(PCM_BYTES_PER_SECOND));
        controller.enqueue(new Uint8Array(PCM_BYTES_PER_SECOND / 2));
        controller.close();
      },
    }).pipeThrough(counting((bytes) => { reported = bytes; }));
    const reader = stream.getReader();
    let total = 0;
    for (;;) { const { done, value } = await reader.read(); if (done) break; total += value.byteLength; }
    expect(total).toBe(PCM_BYTES_PER_SECOND * 1.5);
    expect(reported / PCM_BYTES_PER_SECOND).toBe(1.5);
  });
});
