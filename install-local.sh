#!/bin/bash
# Builds KMLink.app with Developer ID + Hardened Runtime, runs self-tests,
# and installs to /Applications/KMLink.app for local personal use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$ROOT/build/KMLink.app"
APP_DST="/Applications/KMLink.app"
APP_STAGE="/Applications/.KMLink.app.staging.$$"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.local.kmlink.agent.plist"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/ { print $2; exit }' || true)"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "ERROR: No 'Developer ID Application' certificate found in keychain." >&2
  echo "Pass SIGN_IDENTITY=\"Developer ID Application: ...\" or build ad-hoc with ./build.sh." >&2
  exit 1
fi

echo "== 1. Build & sign ($SIGN_IDENTITY + Hardened Runtime) =="
SIGN_IDENTITY="$SIGN_IDENTITY" REQUIRE_DEV_ID=1 "$ROOT/build.sh"

echo "== 2. Verify Mach-O & signature =="
file "$APP_SRC/Contents/MacOS/KMLink" | grep -q "arm64"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"
SIG_INFO="$(codesign -dvv "$APP_SRC" 2>&1)"
echo "$SIG_INFO" | grep -E "Identifier=|TeamIdentifier=|Authority=|Signature="
echo "$SIG_INFO" | grep -q "Authority=Developer ID Application:" || {
  echo "ERROR: App is not signed with a Developer ID certificate." >&2
  exit 1
}

echo "== 3. Run built-in self-tests =="
"$APP_SRC/Contents/MacOS/KMLink" --selftest

echo "== 4. Stop running KMLink cleanly =="
osascript -e 'tell application id "com.local.kmlink" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x KMLink >/dev/null 2>&1 || break
  sleep 0.3
done
if pgrep -x KMLink >/dev/null 2>&1; then
  pkill -TERM -x KMLink >/dev/null 2>&1 || true
  sleep 0.5
fi

echo "== 5. Install to $APP_DST =="
cleanup() {
  rm -rf "$APP_STAGE"
}
trap cleanup EXIT

rm -rf "$APP_STAGE"
ditto "$APP_SRC" "$APP_STAGE"
xattr -dr com.apple.quarantine "$APP_STAGE" 2>/dev/null || true
rm -rf "$APP_DST"
mv "$APP_STAGE" "$APP_DST"

if [ -f "$AGENT_PLIST" ]; then
  launchctl bootout "gui/$(id -u)/com.local.kmlink.agent" >/dev/null 2>&1 || true
  rm -f "$AGENT_PLIST"
fi

codesign --verify --deep --strict "$APP_DST"

echo "== 6. Launch $APP_DST =="
open -a "$APP_DST"
echo "Installed and launched: $APP_DST"
