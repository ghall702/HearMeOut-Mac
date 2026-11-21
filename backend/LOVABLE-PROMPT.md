# Lovable prompt — Mac app support for Hear Me Out

Paste everything below into Lovable.

---

Please add support for the native Hear Me Out Mac app. These are **new files only** plus nothing else:
do **not** modify `src/lib/apikeys.server.ts`, the existing `/api/public/v1` uploads, finalize, recordings or
extension routes, the database schema or RLS.

Checklist:
1. Create each file below at exactly the given path with exactly the given content.
2. Regenerate the route tree so `/native/connect`, `/api/public/v1/native/config`, `/api/public/v1/native/token`,
   `/api/public/v1/me` and `/api/public/v1/recordings/$id/playback` are registered.
3. If `src/routes/index.tsx` redirects signed-in users away from `/` after Google sign-in, add the same exception the
   extension uses: if `sessionStorage.getItem("hmo-native-connect")` is set, navigate to `/native/connect` instead of `/record`.
4. If `getOwnedRecording` doesn't return `storage_key` and `status`, select those columns. If `hmo.server.ts` already has a
   helper that builds a signed `view` URL (used by `getPlaybackUrl`), use it in the playback route instead of `playback.server.ts`.
5. No new secrets are required (optional: `HMO_NATIVE_GRANT_SECRET`). Run `bunx vitest run`.


## `src/lib/native-auth.server.ts`

```ts
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
```

## `src/lib/native-auth.functions.ts`

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { isAllowedNativeRedirect, isValidChallenge, mintNativeCode } from "./native-auth.server";

/** Called by /native/connect after the signed-in user approves the Mac app. */
export const createNativeGrant = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) =>
    z.object({ redirectUri: z.string().max(200), codeChallenge: z.string().max(64), deviceName: z.string().max(60) }).parse(d),
  )
  .handler(async ({ data, context }) => {
    if (!isAllowedNativeRedirect(data.redirectUri)) throw new Error("This app isn't allowed to connect.");
    if (!isValidChallenge(data.codeChallenge)) throw new Error("Invalid sign-in request.");
    return mintNativeCode(context.userId, data.codeChallenge, data.deviceName);
  });
```

## `src/lib/playback.server.ts`

```ts
// Short-lived signed audio URL for the owner (GET /api/public/v1/recordings/:id/playback).
// Uses the documented media-server token format (handbook §5): base64url(JSON {key, op:"view", exp})
// + "." + base64url(HMAC-SHA256(secret, base64urlPayloadText)). If hmo.server.ts already exports a
// view-token/URL helper (as used by getPlaybackUrl), call that instead of this function.
const VIEW_TTL_SECONDS = 15 * 60;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function keyBelongsToUser(key: string, userId: string) {
  return key.startsWith(`users/${userId.toLowerCase()}/`) && !key.includes("..");
}

export async function signedViewUrl(storageKey: string, now = Math.floor(Date.now() / 1000)) {
  const secret = process.env["HEARMEOUT_GATEWAY_SECRET"];
  if (!secret) throw new Error("Media server not configured");
  const base = (process.env["HEARMEOUT_BASE_URL"] ?? "https://mediahub-lm-1.georgehalltuition.com").replace(/\/$/, "");
  const exp = now + VIEW_TTL_SECONDS;
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ key: storageKey, op: "view", exp })));
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = b64url(new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload))));
  return { url: `${base}/hmo/file?key=${encodeURIComponent(storageKey)}&t=${payload}.${sig}`, exp };
}
```

## `src/routes/native.connect.tsx`

```tsx
import { createFileRoute } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useEffect, useState } from "react";
import { Laptop, Loader2, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/hmo/Logo";
import { lovable } from "@/integrations/lovable";
import { supabase } from "@/integrations/supabase/client";
import { ALLOWED_EMAILS } from "@/lib/hmo-core";
import { createNativeGrant } from "@/lib/native-auth.functions";

// Approval page opened by the Hear Me Out Mac app (ASWebAuthenticationSession). On approval it
// redirects to hearmeout://auth/callback with a short-lived, PKCE-bound authorisation code.
export const Route = createFileRoute("/native/connect")({
  ssr: false,
  head: () => ({ meta: [{ title: "Connect the Mac app — Hear Me Out" }, { name: "robots", content: "noindex" }] }),
  component: ConnectNative,
});

const PENDING_KEY = "hmo-native-connect";
const REDIRECT = "hearmeout://auth/callback";
type Pending = { redirectUri: string; state: string; challenge: string; device: string };

function readPending(): Pending | null {
  const q = new URLSearchParams(window.location.search);
  const redirectUri = q.get("redirect_uri");
  const state = q.get("state");
  const challenge = q.get("code_challenge");
  if (redirectUri && state && challenge && q.get("code_challenge_method") === "S256") {
    const p = { redirectUri, state, challenge, device: (q.get("device_name") ?? "Mac").slice(0, 60) };
    sessionStorage.setItem(PENDING_KEY, JSON.stringify(p));
    return p;
  }
  try {
    return JSON.parse(sessionStorage.getItem(PENDING_KEY) ?? "null") as Pending | null;
  } catch {
    return null;
  }
}

function ConnectNative() {
  const grant = useServerFn(createNativeGrant);
  const [pending, setPending] = useState<Pending | null>(null);
  const [email, setEmail] = useState<string | null>(null);
  const [phase, setPhase] = useState<"checking" | "signin" | "approve" | "working" | "done" | "error">("checking");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const p = readPending();
    setPending(p);
    if (!p || p.redirectUri !== REDIRECT || !/^[\w-]{16,128}$/.test(p.state) || !/^[A-Za-z0-9_-]{43}$/.test(p.challenge)) {
      setPhase("error");
      setError("This link is incomplete. In the Hear Me Out Mac app, choose Sign in with Google again.");
      return;
    }
    supabase.auth.getUser().then(({ data }) => {
      const e = data.user?.email?.toLowerCase() ?? null;
      if (data.user && e && ALLOWED_EMAILS.includes(e)) {
        setEmail(e);
        setPhase("approve");
      } else {
        if (data.user) {
          void supabase.auth.signOut();
          setError("That Google account isn't authorised for Hear Me Out.");
        }
        setPhase("signin");
      }
    });
  }, []);

  const finish = (params: Record<string, string>) => {
    if (!pending) return;
    sessionStorage.removeItem(PENDING_KEY);
    const q = new URLSearchParams({ ...params, state: pending.state });
    setPhase("done");
    window.location.replace(`${pending.redirectUri}?${q.toString()}`);
  };

  const signIn = async (switchAccount = false) => {
    setPhase("working");
    if (switchAccount) await supabase.auth.signOut();
    const r = await lovable.auth.signInWithOAuth("google", {
      redirect_uri: `${window.location.origin}/native/connect`,
      extraParams: { prompt: "select_account" },
    });
    if (r.error) {
      setError(/authori|not allowed|Database error/i.test(r.error.message) ? "That Google account isn't authorised for Hear Me Out." : r.error.message);
      setPhase("signin");
      return;
    }
    if (r.redirected) return;
    window.location.reload();
  };

  const approve = async () => {
    setPhase("working");
    try {
      const { code } = await grant({ data: { redirectUri: pending!.redirectUri, codeChallenge: pending!.challenge, deviceName: pending!.device } });
      finish({ code });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not connect the Mac app.");
      setPhase("approve");
    }
  };

  return (
    <div className="grid min-h-dvh place-items-center px-5 py-10">
      <div className="w-full max-w-md animate-rise rounded-[2rem] border bg-card p-7 shadow-soft">
        <Logo />
        <h1 className="mt-8 text-2xl font-semibold">Connect Hear Me Out for Mac</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {pending?.device ? `“${pending.device}”` : "The Mac app"} will be able to record voice notes to your account and list your recordings. It never sees your password, and you can disconnect it in Settings → API keys.
        </p>
        {error && <p className="mt-4 rounded-2xl bg-destructive/10 px-4 py-3 text-sm text-destructive">{error}</p>}
        {phase === "checking" || phase === "working" ? (
          <div className="mt-8 grid place-items-center"><Loader2 className="size-6 animate-spin text-muted-foreground" /></div>
        ) : phase === "done" ? (
          <p className="mt-8 text-sm text-muted-foreground">Done — you can return to the Hear Me Out app.</p>
        ) : phase === "signin" ? (
          <div className="mt-8 space-y-3">
            <Button className="h-12 w-full rounded-full" variant="outline" onClick={() => signIn(false)}>Continue with Google</Button>
            <Button className="w-full rounded-full" variant="ghost" onClick={() => finish({ error: "access_denied" })}>Cancel</Button>
          </div>
        ) : phase === "approve" ? (
          <div className="mt-6 space-y-3">
            <div className="flex items-center gap-3 rounded-2xl bg-muted/60 px-4 py-3 text-sm">
              <ShieldCheck className="size-5 text-primary" />
              <span className="min-w-0 truncate">Signed in as <strong>{email}</strong></span>
            </div>
            <Button className="h-12 w-full rounded-full" variant="hero" onClick={approve}><Laptop /> Connect this Mac</Button>
            <div className="flex gap-2">
              <Button className="flex-1 rounded-full" variant="outline" onClick={() => signIn(true)}>Use a different account</Button>
              <Button className="flex-1 rounded-full" variant="ghost" onClick={() => finish({ error: "access_denied" })}>Cancel</Button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
```

## `src/routes/api/public/v1/native.config.ts`

```ts
import { createFileRoute } from "@tanstack/react-router";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/native/config — lets the Mac app detect that native sign-in is deployed.
export const Route = createFileRoute("/api/public/v1/native/config")({
  server: { handlers: { GET: async () => json({ enabled: true, redirectUris: ["hearmeout://auth/callback"], pkce: ["S256"] }) } },
});
```

## `src/routes/api/public/v1/native.token.ts`

```ts
import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";
import { exchangeNativeCode } from "@/lib/native-auth.server";
import { json } from "@/lib/api-http.server";

// POST /api/public/v1/native/token
//   { grant_type: "authorization_code", code, code_verifier, device_name? }
// → 200 { api_key: "hmo_…", user: { id, email, name, avatar_url } } · 400 invalid_request · 401 invalid_grant · 403 not_allowed
export const Route = createFileRoute("/api/public/v1/native/token")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const parsed = z
          .object({
            grant_type: z.literal("authorization_code"),
            code: z.string().min(20).max(2000),
            code_verifier: z.string().min(43).max(128),
            device_name: z.string().max(60).optional(),
          })
          .safeParse(await request.json().catch(() => null));
        if (!parsed.success) return json({ error: "invalid_request" }, 400);
        try {
          return json(await exchangeNativeCode(parsed.data.code, parsed.data.code_verifier, parsed.data.device_name));
        } catch (e) {
          const msg = e instanceof Error ? e.message : "";
          if (msg === "not_allowed") return json({ error: "not_allowed" }, 403);
          if (msg === "could_not_create_key") return json({ error: "could_not_create_key" }, 500);
          return json({ error: "invalid_grant" }, 401);
        }
      },
    },
  },
});
```

## `src/routes/api/public/v1/me.ts`

```ts
import { createFileRoute } from "@tanstack/react-router";
import { authenticateApiKey } from "@/lib/apikeys.server";
import { profileFor } from "@/lib/native-auth.server";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/me — the profile behind this key (lets API-key clients show the real name/avatar).
export const Route = createFileRoute("/api/public/v1/me")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const auth = await authenticateApiKey(request);
        if (!auth) return json({ error: "unauthorised" }, 401);
        try {
          return json({ user: await profileFor(auth.userId), features: ["native-auth", "playback"] });
        } catch {
          return json({ error: "not_found" }, 404);
        }
      },
    },
  },
});
```

## `src/routes/api/public/v1/recordings.$id.playback.ts`

```ts
import { createFileRoute } from "@tanstack/react-router";
import { authenticateApiKey } from "@/lib/apikeys.server";
import { getOwnedRecording } from "@/lib/recordings.server";
import { keyBelongsToUser, signedViewUrl } from "@/lib/playback.server";
import { json } from "@/lib/api-http.server";

// GET /api/public/v1/recordings/:id/playback — owner-only, 15-minute signed audio URL (supports Range).
// The client never signs storage tokens; audio is streamed directly from the media server.
export const Route = createFileRoute("/api/public/v1/recordings/$id/playback")({
  server: {
    handlers: {
      GET: async ({ request, params }) => {
        const auth = await authenticateApiKey(request);
        if (!auth) return json({ error: "unauthorised" }, 401);
        try {
          const rec = await getOwnedRecording(auth.db, auth.userId, params.id);
          if (rec.status !== "ready") return json({ error: "not_ready" }, 409);
          if (!keyBelongsToUser(rec.storage_key, auth.userId)) return json({ error: "forbidden" }, 403);
          return json(await signedViewUrl(rec.storage_key));
        } catch {
          return json({ error: "not_found" }, 404);
        }
      },
    },
  },
});
```

## `src/test/native-auth.test.ts`

```ts
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
```
