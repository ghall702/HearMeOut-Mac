#!/bin/bash
# Picks the newest installed Xcode (Xcode 26+ enables Apple Intelligence titles via FoundationModels).
set -euo pipefail
ls -d /Applications/Xcode*.app 2>/dev/null || true
BEST=$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -v -i beta | sed -E 's/.*Xcode_([0-9.]+)\.app/\1 &/' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -d' ' -f2- || true)
if [ -n "${BEST:-}" ]; then sudo xcode-select -s "$BEST/Contents/Developer"; fi
xcodebuild -version
