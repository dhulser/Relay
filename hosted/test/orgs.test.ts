import { describe, expect, it } from "vitest";
import { domainOf, parsePolicy } from "../src/orgs";

describe("orgs", () => {
  it("takes the domain from an email", () => {
    expect(domainOf("Dylan@Kevel.co")).toBe("kevel.co");
    expect(domainOf("not-an-email")).toBeNull();
    expect(domainOf("trailing@")).toBeNull();
  });

  it("policy defaults to everything allowed and tolerates junk", () => {
    expect(parsePolicy(null)).toEqual({ allowInstant: true, allowTranscript: true, allowMicrophone: true });
    expect(parsePolicy("{nope")).toEqual({ allowInstant: true, allowTranscript: true, allowMicrophone: true });
    expect(parsePolicy('{"allowInstant":false}')).toEqual({ allowInstant: false, allowTranscript: true, allowMicrophone: true });
  });
});
