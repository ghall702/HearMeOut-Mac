# Test plan and status

Status key: ✅ automated and passing in CI · 🖥️ needs a real Mac with microphone / accounts (not yet run) ·
👀 checked by screenshot review in CI.

## Automated (Packages/HearMeOutCore, `swift test`, runs on every push)

| Area | Tests |
|---|---|
| Pipeline combinations | local+Apple, local+OpenAI, local+Hear Me Out, cloud+cloud, cloud+Apple, none, typed title wins, placeholder title treated as missing |
| Failure handling | title failure keeps transcript & never falls back to cloud titling, local transcription failure keeps share link, no-speech never titles, switch to cloud after local failure |
| Uploads | expired ticket reissued without a second recording, transient failures retried with backoff, server can't find file → re-upload, 15-minute limit rejected locally, offline defers network but transcribes locally |
| Accounts | each item uses its own account's key (isolation), unauthorised pauses only that account and keeps local work, reassign only before a server recording exists |
| Persistence | atomic save with backup recovery, owner-only permissions, queue round-trip, running stages reset after relaunch |
| API | lenient decoding, both ticket shapes, nil fields omitted (missing title stays missing), error mapping, bearer/paths |
| Sign-in | RFC 7636 vector, URL contents, callback validation (state, scheme, denial) |
| Sharing | message text, Gmail HTML + plain text, embed/link |
| Models | Let's Meet layout & tokenizer detection, ggml incompatibility, scanning never modifies files, friendly names |
| Library | merge/search/filter/sort, initials |

## CI on macOS (every push)
* Release build for arm64 with Xcode 26 ✅ · signature/entitlements verified ✅ · launch smoke test with demo data ✅ · DMG ✅
* Screenshots of every main screen in 16 theme/appearance combinations 👀 (commit with `[shots]`) — all 16 captured and reviewed (build 12); two design passes applied from them
* An idle-redraw loop (≈100 state changes/second, caused by the menu bar binding) was found by these screenshot runs and fixed

## First real sign-in (backend now deployed) 🖥️
1. Settings → Accounts → **Sign in with Google**. A browser sheet opens `/native/connect`; pick the account, press
   **Connect this Mac**. Expect: the sheet closes, the account appears with your Google name, email and picture.
2. In the web app, Settings → API keys should list **Mac app · <Mac name> · <date>**.
3. Add the second and third accounts the same way ("Use a different account" on the connect page).
4. Library → select a recording whose local copy isn't on this Mac → it should play (15-minute link).
5. Remove one account in the Mac app → its key should show as revoked in Settings → API keys.
If step 1 fails, note the message shown in the app (it distinguishes cancelled / not authorised / expired code).

## Manual checks on your Macs 🖥️
1. Connect three accounts (Google once the backend is deployed; API key before). Switch repeatedly; check avatar,
   email, theme and library change together and the destination chip is always right.
2. Start recording in Personal, switch to Work mid-recording: the review card still says Personal and warns.
3. Record with built-in, USB and Bluetooth microphones; unplug the chosen one (falls back, notice shown);
   unplug mid-recording (recording stops, audio kept, note shown).
4. Pause/resume; switch apps and Spaces while recording; minimise the window; let a recording reach 15:00.
5. Import M4A, MP3, WAV, FLAC, OGG/WebM (cloud transcription suggested), AIFF (converted), a 20-minute file (rejected).
6. Find Let's Meet's model; transcribe locally; confirm Let's Meet still works and its folder is unchanged.
7. Apple Intelligence on/off; OpenAI good key, bad key, out-of-credit key; manual title kept.
8. Turn Wi-Fi off during an upload; quit and relaunch mid-upload; confirm no duplicates in the web library.
9. Copy for Gmail into a Gmail draft; Copy HTML Embed into a page; menu bar copy-latest-link; global shortcuts.
10. Large library (200 items) scrolling; VoiceOver labels; Reduce Motion; window at 860×600 and full screen on a 14" and 16" display.
