#!/bin/bash
# Hear Me Out for Mac — one-line installer.
#   curl -fsSL https://github.com/ghall702/HearMeOut-Mac/releases/latest/download/install.sh | bash
# Downloads the latest DMG from GitHub Releases, copies the app to /Applications and opens it.
set -euo pipefail
URL="https://github.com/ghall702/HearMeOut-Mac/releases/latest/download/Hear-Me-Out.dmg"
APP="Hear Me Out.app"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Hear Me Out needs an Apple Silicon Mac (M1 or later)." >&2; exit 1
fi

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "→ Downloading the latest Hear Me Out…"
curl -fL --progress-bar "$URL" -o "$TMP/Hear-Me-Out.dmg"

echo "→ Installing to /Applications…"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/Hear-Me-Out.dmg" -nobrowse -quiet -mountpoint "$TMP/mnt"
if pgrep -x HearMeOut >/dev/null; then
  echo "  Quitting the running copy first…"
  osascript -e 'quit app "Hear Me Out"' || true
  sleep 2
fi
if [ -w /Applications ]; then
  rm -rf "/Applications/$APP"
  cp -R "$TMP/mnt/$APP" /Applications/
else
  sudo rm -rf "/Applications/$APP"
  sudo cp -R "$TMP/mnt/$APP" /Applications/
fi
# The app isn't notarised; clear the download flag so macOS opens it without the warning dialog.
xattr -dr com.apple.quarantine "/Applications/$APP" 2>/dev/null || true

echo "✓ Installed. Opening Hear Me Out…"
open "/Applications/$APP"
