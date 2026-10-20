#!/bin/bash
# Installs (or updates) Lex in ~/Applications and opens it:
#
#   curl -fsSL https://raw.githubusercontent.com/matanweks/Lex/main/scripts/install.sh | bash
#
# Lex is built on your Mac from this repository, so there's nothing for macOS to quarantine.
# Your settings and API key are kept across updates.
set -euo pipefail

REPO="https://github.com/matanweks/Lex"
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Lex is a Mac app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Lex needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

# Building needs Apple's developer tools with the macOS 26 SDK (for on-device dictation).
if ! xcrun --find swift >/dev/null 2>&1; then
  bold "Lex is built on your Mac, which needs Apple's Command Line Tools."
  xcode-select --install >/dev/null 2>&1 || true
  fail "Finish installing the tools in the window that opened, then run this again."
fi
sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
[ "${sdk:-0}" -ge 26 ] || fail "Building Lex needs the macOS 26 SDK (Xcode or Command Line Tools 26 or later); found ${sdk:-none}. Update them in System Settings › General › Software Update."

# Use this checkout when run from one; otherwise download the latest source.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/build.sh" ] && [ -f "$here/../Package.swift" ]; then
  src="$here/.."
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  bold "Downloading Lex…"
  curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$work"
  src="$work/Lex-main"
fi

bold "Building Lex (about a minute the first time)…"
"$src/scripts/build.sh" --open

bold "Lex is installed in ~/Applications and running."
echo "The setup guide that just opened walks you through the rest. Look for the L. in your menu bar."
