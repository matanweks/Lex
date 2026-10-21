#!/bin/bash
# Builds Lex for iPhone and installs it on the iPhone connected to this Mac:
#
#   scripts/install-iphone.sh
#
# Apps signed with a free Apple developer account stop opening after 7 days; run this again
# to renew it (your settings, words and clipboard history are kept). The phone must be
# connected (cable or the same Wi-Fi) and unlocked.
#
# It signs with the team that signed Lex before (from Xcode's profiles), or your only "Apple
# Development" certificate (Xcode makes it when you add your Apple Account in Xcode › Settings ›
# Accounts). To pick a team, run it with LEX_TEAM=<team ID>; to pick a phone, LEX_DEVICE=<its
# identifier from `xcrun devicectl list devices`>.
set -euo pipefail

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/build/iphone"
xcrun --find xcodebuild >/dev/null 2>&1 || fail "Building for iPhone needs Xcode."

# The team: asked for, or the one the last install used, or the one in Xcode's profile for
# Lex, or the only one there is.
mkdir -p "$root/build"
team="${LEX_TEAM:-$(cat "$build.team" 2>/dev/null || true)}"
if [ -z "$team" ]; then
  for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*; do
    [ -f "$profile" ] || continue
    id=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    if [ "${id#*.}" = "dev.lex.ios" ]; then team="${id%%.*}"; break; fi
  done
fi
if [ -z "$team" ]; then
  teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | awk '/BEGIN/ { cert = "" } { cert = cert $0 "\n" } /END/ { printf "%s", cert | "openssl x509 -noout -subject"; close("openssl x509 -noout -subject") }' \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u)
  [ -n "$teams" ] || fail "No Apple Development certificate. In Xcode › Settings › Accounts, add your Apple Account, then run this again."
  [ "$(printf "%s\n" "$teams" | wc -l | tr -d ' ')" = 1 ] || fail "You have more than one team ($(echo $teams)). Run it with LEX_TEAM=<the one to use>."
  team="$teams"
fi

device="${LEX_DEVICE:-}"
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$|^[0-9A-F-]{36}$/) { print $i; exit } }')
  [ -n "$device" ] || fail "No iPhone found. Connect it with a cable (or turn on Wi-Fi syncing), unlock it, and run this again."
fi

bold "Building Lex (team $team)…"
xcodebuild -project "$root/iOS/Lex.xcodeproj" -scheme Lex -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$build" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates build >"$build.log" 2>&1 \
  || { grep -E "error:" "$build.log" | head -5 >&2; fail "The build failed; the full log is in $build.log."; }
app="$build/Build/Products/Release-iphoneos/Lex.app"

bold "Installing on the iPhone…"
if ! out=$(xcrun devicectl device install app --device "$device" "$app" 2>&1); then
  printf "%s\n" "$out" | grep -iE "error|locked|trust" | head -3 >&2
  fail "Couldn't install. Unlock the iPhone (and tap Trust if it asks), then run this again."
fi

expires=$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)
echo "$team" >"$build.team"
bold "Lex is on your iPhone."
# The profile's date is in UTC; say it in local time.
until=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null | xargs -I{} date -r {} "+%A %-d %B, %H:%M" 2>/dev/null || true)
[ -n "$expires" ] && echo "This install works until ${until:-$expires}. Run this again before then."
echo "The first time, trust the developer in Settings › General › VPN & Device Management."
