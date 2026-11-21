#!/bin/bash
# Usage: scripts/make-dmg.sh "path/to/Hear Me Out.app" output.dmg
set -euo pipefail
APP="$1"; OUT="$2"
STAGE="$(mktemp -d)/Hear Me Out"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Hear Me Out" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
