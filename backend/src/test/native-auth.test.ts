import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { isAllowedNativeRedirect, isValidChallenge, isValidVerifier, nativeKeyName, openCode, s256, sealCode } from "@/lib/native-auth.server";
import { keyBelongsToUser, signedViewUrl } from "@/lib/playback.server";

describe("Mac app sign-in", () => {
  beforeEach(() => { process.env["HEARMEOUT_GATEWAY_SECRET"] = "test-secret"; });
  afterEach(() => { delete process.env["HMO_NATIVE_REDIRECTS"]; delete process.env["HMO_NATIVE_GRANT_SECRET"]; });

  it("computes RFC 7636 S256 challenges", async () => {
    expect(await s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")).toBe("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
  });

  it("only accepts the registered redirect", () => {
    expect(isAllowedNativeRedirect("hearmeout://auth/callback")).toBe(true);
    expect(isAllowedNativeRedirect("hearmeout://auth/callback/../x")).toBe(false);
    expect(isAllowedNativeRedirect("https://evil.example/")).toBe(false);
  });

  it("validates PKCE inputs", () => {
    expect(isValidChallenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")).toBe(true);
    expect(isValidChallenge("short")).toBe(false);
    expect(isValidVerifier("a".repeat(42))).toBe(false);
    expect(isValidVerifier("a".repeat(43))).toBe(true);
  });

  it("seals codes that can't be forged or reused after expiry", async () => {
    const code = await sealCode({ th: "hash", cc: "c".repeat(43), exp: Math.floor(Date.now() / 1000) + 60, dn: "Mac" });
    expect((await openCode(code))?.th).toBe("hash");
    const [body] = code.split(".");
    expect(await openCode(`${body}.AAAA`)).toBeNull();
    expect(await openCode(code, Date.now() / 1000 + 3600)).toBeNull();
  });

  it("names keys recognisably", () => {
    expect(nativeKeyName("George’s MacBook Pro", new Date(2026, 10, 21))).toBe("Mac app · George’s MacBook Pro · 21 Nov 2026");
  });

  it("signs playback URLs only for the owner's keys", async () => {
    expect(keyBelongsToUser("users/abc/x.m4a", "ABC")).toBe(true);
    expect(keyBelongsToUser("users/other/x.m4a", "abc")).toBe(false);
    const { url } = await signedViewUrl("users/abc/x.m4a", 1000);
    expect(url).toContain("/hmo/file?key=users%2Fabc%2Fx.m4a&t=");
  });
});
