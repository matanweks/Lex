#!/bin/bash
# Builds Lex for iPhone and installs it on the iPhone connected to this Mac:
#
#   scripts/install-iphone.sh                    build and install it now
#   scripts/install-iphone.sh --auto-renew on    keep it renewed by itself (off to stop)
#
# Apps signed with a free Apple developer account stop opening 7 days after Apple issued their
# signing profiles. When the profiles Xcode has are more than a day old, this asks Apple for
# new ones first, so each install gives Lex a full 7 days. Your settings, words and clipboard
# history are kept. The phone must be unlocked and connected: a cable, or the same Wi-Fi once
# it's paired.
#
# --auto-renew on adds a launchd job that runs this every two hours with --if-due: it does
# nothing until Lex has less than two days left, then installs as soon as it finds the phone
# unlocked, and shows a notification when Lex is about to stop working. It logs to
# ~/Library/Logs/Lex-iPhone.log. The job runs this file, so keep the repository where it is.
#
# It signs with the team that signed Lex before (from Xcode's profiles), or your only "Apple
# Development" certificate (Xcode makes it when you add your Apple Account in Xcode › Settings ›
# Accounts). To pick a team, run it with LEX_TEAM=<team ID>; to pick a phone, LEX_DEVICE=<its
# identifier from `xcrun devicectl list devices`>.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/build/iphone"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
label="dev.lex.iphone-renew"
agent="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/Lex-iPhone.log"
day=86400
mode=install
left=0

if [ -t 1 ]; then
  bold() { printf "\033[1m%s\033[0m\n" "$1"; }
else
  bold() { printf "%s %s\n" "$(date "+%Y-%m-%d %H:%M")" "$1"; }
fi
notify() { osascript -e "display notification \"$1\" with title \"Lex\"" >/dev/null 2>&1 || true; }
# A profile's dates are in UTC; this says them in local time.
epoch() { TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || true; }
when() { date -r "$1" "+%A %-d %B, %H:%M"; }

fail() {
  printf "%s\n" "$1" >&2
  # Run by the job with less than a day left: say so, at most every 6 hours.
  if [ "$mode" = due ] && [ "$left" -lt "$day" ]; then
    last=$(cat "$build.notified" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - last )) -gt $(( 6 * 3600 )) ]; then
      if [ "$left" -gt 0 ]; then
        notify "Lex on your iPhone stops working $(when "$(cat "$build.expires")"). Unlock the iPhone near this Mac to renew it."
      else
        notify "Lex on your iPhone needs renewing. Unlock the iPhone near this Mac."
      fi
      date +%s >"$build.notified"
    fi
  fi
  exit 1
}

mkdir -p "$root/build"

case "${1:-}" in
  "") ;;
  --if-due) mode=due ;;
  --auto-renew)
    case "${2:-}" in
      on)
        mkdir -p "$(dirname "$agent")" "$(dirname "$log")"
        cat >"$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$root/scripts/install-iphone.sh</string>
		<string>--if-due</string>
	</array>
	<key>StartInterval</key>
	<integer>7200</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
PLIST
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$agent"
        bold "Lex will renew itself on your iPhone."
        if [ -f "$build.expires" ]; then
          echo "The install works until $(when "$(cat "$build.expires")"); from two days before, the Mac renews it the first time it finds the iPhone unlocked."
        fi
        echo "It checks every two hours while you're logged in. To stop: scripts/install-iphone.sh --auto-renew off"
        exit 0 ;;
      off)
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        rm -f "$agent"
        bold "Automatic renewal is off."
        exit 0 ;;
      *) fail "Use --auto-renew on, or --auto-renew off." ;;
    esac ;;
  *) fail "Unknown option $1. Run it with no options to install, or with --auto-renew on|off." ;;
esac

if [ "$mode" = due ]; then
  left=$(( $(cat "$build.expires" 2>/dev/null || echo 0) - $(date +%s) ))
  # Quiet until two days are left.
  [ "$left" -lt $(( 2 * day )) ] || exit 0
  bold "Lex has $(( left / 3600 )) hours left on the iPhone; renewing."
fi

# One at a time (the job and a run by hand).
mkdir "$build.lock" 2>/dev/null || { echo "Another install is running."; exit 0; }
trap 'rmdir "$build.lock" 2>/dev/null || true' EXIT

xcrun --find xcodebuild >/dev/null 2>&1 || fail "Building for iPhone needs Xcode."

# The team: asked for, or the one the last install used, or the one in Xcode's profile for
# Lex, or the only one there is.
team="${LEX_TEAM:-$(cat "$build.team" 2>/dev/null || true)}"
if [ -z "$team" ]; then
  for profile in "$profiles/"*; do
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
  [ -n "$device" ] || fail "No iPhone found. Connect it with a cable (or keep it on the same Wi-Fi), unlock it, and run this again."
fi

app="$build/Build/Products/Release-iphoneos/Lex.app"
built=$(epoch "$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)")
if [ "$mode" = due ] && [ -n "$built" ] && [ $(( built - $(date +%s) )) -gt $(( 6 * day )) ]; then
  # The job tried earlier and the phone wasn't there: that build is still fresh.
  bold "Using the build from earlier."
else
  # Lex's profiles that are more than a day old go aside, so Xcode asks Apple for new ones and
  # this install gets the full 7 days. They come back if the build fails.
  aside="$build-old-profiles"
  rm -rf "$aside"
  mkdir -p "$aside"
  for profile in "$profiles/"*; do
    [ -f "$profile" ] || continue
    data=$(security cms -D -i "$profile" 2>/dev/null || true)
    id=$(printf "%s" "$data" | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    case "$id" in "$team.dev.lex.ios" | "$team.dev.lex.ios."*) ;; *) continue ;; esac
    expires=$(epoch "$(printf "%s" "$data" | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)")
    if [ -z "$expires" ] || [ $(( expires - $(date +%s) )) -lt $(( 6 * day )) ]; then mv "$profile" "$aside/"; fi
  done

  bold "Building Lex (team $team)…"
  if ! xcodebuild -project "$root/iOS/Lex.xcodeproj" -scheme Lex -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$build" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates build >"$build.log" 2>&1; then
    for profile in "$aside/"*; do [ -f "$profile" ] && mv "$profile" "$profiles/"; done
    grep -E "error:" "$build.log" | head -5 >&2 || true
    fail "The build failed; the full log is in $build.log."
  fi
  rm -rf "$aside"
fi

bold "Installing on the iPhone…"
if ! out=$(xcrun devicectl device install app --device "$device" "$app" 2>&1); then
  printf "%s\n" "$out" | grep -iE "error|locked|trust" | head -3 >&2 || true
  fail "Couldn't install. Unlock the iPhone (and tap Trust if it asks), then run this again."
fi

echo "$team" >"$build.team"
expires=$(epoch "$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)")
bold "Lex is on your iPhone."
if [ -n "$expires" ]; then
  echo "$expires" >"$build.expires"
  rm -f "$build.notified"
  echo "This install works until $(when "$expires")."
  [ "$mode" = due ] && notify "Lex is renewed on your iPhone until $(when "$expires")."
fi
if [ "$mode" = install ]; then
  if [ -f "$agent" ]; then
    echo "The Mac renews it by itself before then."
  else
    echo "Run this again before then, or turn on automatic renewal: scripts/install-iphone.sh --auto-renew on"
  fi
  echo "The first time, trust the developer in Settings › General › VPN & Device Management."
fi
