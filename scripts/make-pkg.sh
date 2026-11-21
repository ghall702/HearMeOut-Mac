#!/bin/bash
# Usage: scripts/make-pkg.sh "path/to/Hear Me Out.app" output.pkg version
# Builds a standard macOS installer package that puts Hear Me Out in /Applications.
set -euo pipefail
APP="$1"; OUT="$2"; VERSION="${3:-1.0.0}"
WORK="$(mktemp -d)"
mkdir -p "$WORK/root/Applications"
cp -R "$APP" "$WORK/root/Applications/"
# Always install to /Applications (don't "relocate" onto an older copy elsewhere on disk).
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
  --identifier uk.george-hall.hearmeout.pkg --version "$VERSION" --install-location / "$WORK/HearMeOut-component.pkg"
productbuild --synthesize --package "$WORK/HearMeOut-component.pkg" "$WORK/distribution.xml"
# Friendly installer title and Apple Silicon requirement.
sed -i '' 's#<installer-gui-script minSpecVersion="[0-9]*">#&<title>Hear Me Out</title><options hostArchitectures="arm64"/>#' "$WORK/distribution.xml"
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$OUT"
rm -rf "$WORK"
