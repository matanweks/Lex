#!/bin/bash
# Builds Quill.app, signs it, and installs it to ~/Applications.
# Signing with your Apple Development identity (when present) keeps the Accessibility
# grant and Keychain access across rebuilds; an ad-hoc signature loses both every build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Quill

APP=build/Quill.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Quill "$APP/Contents/MacOS/Quill"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
codesign --force --sign "${IDENTITY:--}" --identifier dev.quill.app "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

DEST="$HOME/Applications/Quill.app"
mkdir -p "$HOME/Applications"
pkill -x Quill 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"

if [[ "${1:-}" == "--open" ]]; then
  open "$DEST"
fi
