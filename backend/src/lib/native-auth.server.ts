// Native (macOS) app sign-in. Server-only.
//
// RFC 8252 "OAuth for native apps" pattern on top of the existing Google sign-in:
//  1. The Mac app opens /native/connect in the system browser session (ASWebAuthenticationSession)
//     with a PKCE S256 code_challenge, a random state and redirect_uri=hearmeout://auth/callback.
//  2. The signed-in user approves. createNativeGrant mints a single-use Supabase magic-link token hash
//     (no email is sent) and seals it, together with the code_challenge, into a short-lived HMAC-signed
//     authorisation code. The page redirects to hearmeout://auth/callback?code=…&state=…
//  3. The app POSTs the code and its code_verifier to /api/public/v1/native/token. The server checks the
//     seal, expiry and SHA-256(verifier) == challenge, redeems the single-use token hash (proving the
//     grant and that it wasn't used before), re-checks the allow-list and issues a dedicated `hmo_` key
//     named "Mac app · <device> · <date>" (listed and revocable in Settings → API keys).
// An intercepted code is useless without the verifier, which never leaves the Mac.
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import { ALLOWED_EMAILS } from "./hmo-core";
import { newApiKey, sha256Hex } from "./apikeys.server";

export const NATIVE_REDIRECT_URI = "hearmeout://auth/callback";
const CODE_TTL_SECONDS = 300;

export const isAllowedEmail = (email: string | null | undefined) => !!email && ALLOWED_EMAILS.includes(email.toLowerCase());

/** Only exact, pre-registered redirect URIs are accepted (HMO_NATIVE_REDIRECTS, comma-separated, overrides). */
export function isAllowedNativeRedirect(uri: string): boolean {
  const list = (process.env["HMO_NATIVE_REDIRECTS"] ?? NATIVE_REDIRECT_URI).split(",").map((s) => s.trim()).filter(Boolean);
  return list.includes(uri);
}

export const isValidChallenge = (c: string) => /^[A-Za-z0-9_-]{43}$/.test(c);
export const isValidVerifier = (v: string) => /^[A-Za-z0-9._~-]{43,128}$/.test(v);

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): string {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
}

/** S256 code challenge for a verifier (RFC 7636 §4.2). */
export async function s256(verifier: string): Promise<string> {
  return b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
}

/** Grant-sealing key: HMO_NATIVE_GRANT_SECRET if set, else derived from the gateway secret with domain separation. */
async function sealKey(): Promise<CryptoKey> {
  const explicit = process.env["HMO_NATIVE_GRANT_SECRET"];
  let raw: Uint8Array;
  if (explicit) {
    raw = new TextEncoder().encode(explicit);
  } else {
    const gateway = process.env["HEARMEOUT_GATEWAY_SECRET"];
    if (!gateway) throw new Error("Native sign-in is not configured");
    const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(gateway), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    raw = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode("hmo-native-grant-v1")));
  }
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

type Sealed = { th: string; cc: string; exp: number; dn: string };

export async function sealCode(payload: Sealed): Promise<string> {
  const body = b64url(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await sealKey(), new TextEncoder().encode(body));
  return `${body}.${b64url(sig)}`;
}

export async function openCode(code: string, now = Date.now() / 1000): Promise<Sealed | null> {
  const [body, sig] = code.split(".");
  if (!body || !sig || code.length > 2000) return null;
  const sigBytes = Uint8Array.from(b64urlDecode(sig), (c) => c.charCodeAt(0));
  const ok = await crypto.subtle.verify("HMAC", await sealKey(), sigBytes, new TextEncoder().encode(body));
  if (!ok) return null;
  try {
    const p = JSON.parse(b64urlDecode(body)) as Sealed;
    if (typeof p.exp !== "number" || p.exp < now) return null;
    return p;
  } catch {
    return null;
  }
}

export function nativeKeyName(deviceName: string, now = new Date()) {
  const d = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" }).format(now);
  const device = deviceName.replace(/[^\p{L}\p{N} '’._-]/gu, "").trim().slice(0, 30) || "Mac";
  return `Mac app · ${device} · ${d}`.slice(0, 60);
}

export function userPayload(user: { id: string; email?: string | undefined; user_metadata?: Record<string, unknown> | undefined }) {
  const meta = user.user_metadata ?? {};
  return {
    id: user.id,
    email: user.email ?? null,
    name: (meta["full_name"] as string | undefined) ?? (meta["name"] as string | undefined) ?? null,
    avatar_url: (meta["avatar_url"] as string | undefined) ?? (meta["picture"] as string | undefined) ?? null,
  };
}

/** Called by /native/connect after approval: returns the sealed authorisation code. */
export async function mintNativeCode(userId: string, codeChallenge: string, deviceName: string) {
  if (!isValidChallenge(codeChallenge)) throw new Error("Invalid code challenge");
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const { data: u, error: ue } = await supabaseAdmin.auth.admin.getUserById(userId);
  const email = u?.user?.email;
  if (ue || !email) throw new Error("Account not found");
  if (!isAllowedEmail(email)) throw new Error("That Google account isn't authorised for Hear Me Out.");
  const { data, error } = await supabaseAdmin.auth.admin.generateLink({ type: "magiclink", email });
  const th = data?.properties?.hashed_token;
  if (error || !th) throw new Error("Could not create a sign-in grant");
  const code = await sealCode({ th, cc: codeChallenge, exp: Math.floor(Date.now() / 1000) + CODE_TTL_SECONDS, dn: deviceName.slice(0, 60) });
  return { code };
}

function anonClient() {
  const url = process.env["SUPABASE_URL"];
  const key = process.env["SUPABASE_PUBLISHABLE_KEY"];
  if (!url || !key) throw new Error("Supabase is not configured");
  return createClient<Database>(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storage: undefined } });
}

/** Code + verifier → dedicated per-Mac API key. Errors: invalid_grant, not_allowed, could_not_create_key. */
export async function exchangeNativeCode(code: string, verifier: string, deviceName?: string) {
  if (!isValidVerifier(verifier)) throw new Error("invalid_grant");
  const sealed = await openCode(code);
  if (!sealed) throw new Error("invalid_grant");
  if ((await s256(verifier)) !== sealed.cc) throw new Error("invalid_grant");
  const sb = anonClient();
  let { data, error } = await sb.auth.verifyOtp({ token_hash: sealed.th, type: "magiclink" });
  if (error || !data.session) ({ data, error } = await sb.auth.verifyOtp({ token_hash: sealed.th, type: "email" }));
  if (error || !data.session || !data.user) throw new Error("invalid_grant");
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  await supabaseAdmin.auth.admin.signOut(data.session.access_token, "local").catch(() => undefined);
  if (!isAllowedEmail(data.user.email)) throw new Error("not_allowed");
  const key = newApiKey();
  const { error: insErr } = await supabaseAdmin.from("api_keys").insert({
    user_id: data.user.id,
    name: nativeKeyName(deviceName || sealed.dn),
    key_prefix: key.slice(0, 10),
    key_hash: await sha256Hex(key),
  });
  if (insErr) throw new Error("could_not_create_key");
  return { api_key: key, user: userPayload(data.user) };
}

/** Profile for GET /me. */
export async function profileFor(userId: string) {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const { data, error } = await supabaseAdmin.auth.admin.getUserById(userId);
  if (error || !data.user) throw new Error("not_found");
  return userPayload(data.user);
}
