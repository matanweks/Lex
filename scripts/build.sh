#!/bin/bash
# Builds Lex.app, signs it, and installs it to ~/Applications.
# Signing with your Apple Development identity (when present) keeps the Accessibility
# grant and Keychain access across rebuilds; an ad-hoc signature loses both every build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Lex

APP=build/Lex.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lex "$APP/Contents/MacOS/Lex"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
codesign --force --sign "${IDENTITY:--}" --identifier dev.lex.app "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

DEST="$HOME/Applications/Lex.app"
mkdir -p "$HOME/Applications"
# Quit the running copy and wait until it's really gone: reopening while macOS is still
# tearing it down can leave the new launch suspended.
if pkill -x Lex 2>/dev/null; then
  for _ in $(seq 1 30); do pgrep -x Lex >/dev/null || break; sleep 0.1; done
  pkill -9 -x Lex 2>/dev/null || true
  sleep 0.3
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"

if [[ "${1:-}" == "--open" ]]; then
  open "$DEST"
fi
