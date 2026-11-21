# Hear Me Out — Technical Handbook addendum: the Mac app

Adds to the handbook dated 21 Nov 2026. Everything here is additive; existing clients are unaffected.

## 12. macOS client

* **Bundle id** `uk.george-hall.hearmeout`, sandboxed, Hardened Runtime, arm64. Data lives in
  `~/Library/Containers/uk.george-hall.hearmeout/Data/Library/Application Support/Hear Me Out/`.
* **Credentials:** one `hmo_` key per account in the Keychain (`uk.george-hall.hearmeout`, account `hmo-key:<user id>`).
  Keys created by native sign-in are named `Mac app · <device> · <date>` in Settings → API keys.
* **Upload flow:** `POST /uploads` → background `URLSession` `PUT` to the media server → `POST /finalize`
  with `transcribe:false` (fast share link) → optional second `finalize` with `transcript`/`title`/`titleIsAi`, or
  `transcribe:true` for cloud transcription. Expired tickets use `POST /recordings/:id/upload-url` (409 means the
  recording was already finalised, so the app moves straight to finalise).
* **Titles:** the app never sends `Untitled recording`. With Mac-generated or manual titles it sends a provisional
  `Voice note · d MMM yyyy, HH:mm` first, so server auto-titling only runs when the user chose Hear Me Out titles.
* **`recordedAt`:** captured when recording starts (or from trustworthy file metadata on import), sent as UTC
  `yyyy-MM-ddTHH:mm:ssZ` on both `/uploads` and the first `finalize`.

## 13. New endpoints (see backend/README.md)

### `GET /api/public/v1/native/config`
`{ "enabled": true, "redirectUris": ["hearmeout://auth/callback"], "pkce": ["S256"] }`. Clients use a 404 to
fall back to API-key connection.

### `/native/connect` (page)
Query: `client=mac`, `redirect_uri=hearmeout://auth/callback` (exact match), `state` (16–128 url-safe chars),
`code_challenge` (43 chars, S256), `code_challenge_method=S256`, `device_name`, `prompt=select_account`.
On approval redirects to `hearmeout://auth/callback?code=…&state=…`; on cancel `?error=access_denied&state=…`.

### `POST /api/public/v1/native/token`
Body `{ "grant_type":"authorization_code", "code":"…", "code_verifier":"…", "device_name":"…" }` →
`200 { api_key, user:{id,email,name,avatar_url} }`. Errors: 400 `invalid_request`, 401 `invalid_grant`
(bad seal, expired after 5 min, PKCE mismatch, already used), 403 `not_allowed`.

### `GET /api/public/v1/me`
Bearer key → `{ user:{id,email,name,avatar_url}, features:["native-auth","playback"] }`.

### `GET /api/public/v1/recordings/:id/playback`
Bearer key, owner only → `{ url, exp }`: a 15-minute media-server `view` URL (Range supported). 404 if not yours,
409 `not_ready` if the recording isn't finalised.

Revoking a Mac key: `POST /api/public/v1/extension/signout` (already revokes whichever key it is called with).
