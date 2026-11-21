# Backend additions for the Mac app

> **Status: deployed to hearmeout.george-hall.uk (21 Nov 2026).** Added as written, plus the sign-in page
> change that returns Mac sign-ins to `/native/connect`. One difference: `src/lib/playback.server.ts` was
> **not** used. The playback route builds its link with the website's existing view-link code, so links are
> identical to the web app's. Server tests: 30 passing. Smoke-checked: connect page loads, `native/config`
> reports enabled, bad codes and keyless requests are rejected. Not yet exercised: a full sign-in from the app.

The Mac app works with today's Hear Me Out API. Three small, **additive** endpoints make it better.
Nothing existing is changed: the web app, the Chrome extension, `apikeys.server.ts`, uploads,
`finalize` and `recordings` behave exactly as before. No new tables, no migrations.

| Addition | Why | Without it |
|---|---|---|
| **Native Google sign-in** — `/native/connect` page, `GET /api/public/v1/native/config`, `POST /api/public/v1/native/token` | Sign in to all three accounts with Google from the Mac, no pasted keys | The app offers API-key connection instead |
| **`GET /api/public/v1/me`** | Shows the real Google name, email and picture for API-key connections | API-key accounts show initials and a label you choose |
| **`GET /api/public/v1/recordings/:id/playback`** | Play recordings in the Mac library once the local copy has been cleared | The app plays its local copy, or opens the share page in the browser |

**To deploy:** paste [`LOVABLE-PROMPT.md`](LOVABLE-PROMPT.md) into Lovable, or copy the files under
`backend/src/` into the app repository at the same paths (then regenerate `routeTree.gen.ts`).

## Native sign-in flow (RFC 8252 + PKCE)

```
Mac app                                   Hear Me Out web app                         Supabase Auth
verifier = random(48 bytes); challenge = S256(verifier); state = random
ASWebAuthenticationSession ─────────────▶ /native/connect?redirect_uri=hearmeout://auth/callback
                                            &state=…&code_challenge=…&code_challenge_method=S256&device_name=…
                                          Google sign-in (existing flow, allow-list enforced)
                                          "Connect this Mac"
                                          createNativeGrant ─────────────────────────▶ admin.generateLink (no email)
                                          code = HMAC-seal{token_hash, challenge, exp(5 min), device}
◀── hearmeout://auth/callback?code=…&state=…   (delivered only to the session that opened it)
check state
POST /api/public/v1/native/token ───────▶ verify seal + expiry + S256(verifier) == challenge
  {code, code_verifier, device_name}      verifyOtp(token_hash)  ← single-use ─────────▶
                                          allow-list again → insert api_keys row "Mac app · <device> · <date>"
◀── { api_key: "hmo_…", user: {id,email,name,avatar_url} }   (stored in the macOS Keychain)
```

Security properties:

* **PKCE:** an intercepted code is useless without the verifier, which never leaves the Mac.
* **Exact redirect allow-list:** only `hearmeout://auth/callback` (override with `HMO_NATIVE_REDIRECTS`).
* **Short-lived, single-use:** codes expire after 5 minutes; the sealed Supabase token hash can be redeemed once.
* **Allow-list checked twice** (when the grant is created and when it's exchanged); RLS and the DB trigger still apply.
* **Scoped, revocable credential:** each Mac gets its own `hmo_` key, listed in Settings → API keys and revoked
  by the app's "Remove account" (`POST /extension/signout`, which already revokes any key it's called with).
* **No new secret required:** codes are sealed with `HMO_NATIVE_GRANT_SECRET` if set, otherwise with a key derived
  from `HEARMEOUT_GATEWAY_SECRET` using HMAC domain separation (`"hmo-native-grant-v1"`). The gateway secret itself
  never leaves the server.

Why not reuse the Chrome flow? It only accepts `https://<extension-id>.chromiumapp.org/` callbacks, which
Chrome delivers to one extension; a Mac app can't receive those, and the extension grant has no PKCE binding.

## Playback

`GET /recordings/:id/playback` checks the API key, loads the recording with `getOwnedRecording` (RLS-scoped to
the owner), confirms `status = ready` and `keyBelongsTo`, then returns `{ url, exp }` — a 15-minute `view` URL on
the media server (Range supported). Audio is streamed straight from the media server, never through the web app.
If `hmo.server.ts` already exposes the view-URL helper used by `getPlaybackUrl`, use it instead of
`playback.server.ts`.

## Fast share links and transcripts (no change needed)

The Mac app finalises with `transcribe:false` first, so the share link appears straight away (exactly like the
Chrome extension). It then calls `finalize` again to attach the local transcript/title, or with
`transcribe:true` to start cloud transcription. If a future version adds an explicit asynchronous endpoint, the
app's pipeline (`Packages/HearMeOutCore/.../Pipeline.swift`) is the single place to adopt it.

## Tests

`src/test/native-auth.test.ts` covers the RFC 7636 S256 vector, redirect validation, PKCE input validation,
code sealing (forgery and expiry), key naming and playback-key ownership. Run `bunx vitest run`.
