import { describe, expect, it } from "vitest";
import { instructions, LANGUAGES, LANGUAGE_CODES } from "../src/prompt";

describe("prompt", () => {
  it("names the target and leaves the source open when auto-detecting", () => {
    const text = instructions("English");
    expect(text).toContain("ONLY the English translation");
    expect(text).toContain("whatever language the speaker is using");
  });

  it("names a fixed source when given", () => {
    expect(instructions("English", "Spanish")).toContain("spoken Spanish");
  });

  it("offers the same 34 languages as the app, by name and by code", () => {
    expect(LANGUAGES.size).toBe(34);
    expect(LANGUAGE_CODES.size).toBe(34);
  });
});
