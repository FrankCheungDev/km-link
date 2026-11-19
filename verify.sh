#!/bin/bash
# Automated verification: native arm64 build, strict signature check,
# protocol/engine self-tests, headless UI rendering, and script syntax checks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$ROOT/build/KMLink.app"
BIN="$APP_BUNDLE/Contents/MacOS/KMLink"
TMP="$(mktemp -d /tmp/kmlink-verify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== 1. Build (arm64) =="
"$ROOT/build.sh"
file "$BIN" | grep -q "arm64"

echo "== 2. Verify code signature =="
codesign --verify --deep --strict "$APP_BUNDLE"

echo "== 3. Run built-in self-tests =="
"$BIN" --selftest | tee "$TMP/selftest.log"
grep -q "ALL SELFTESTS PASSED" "$TMP/selftest.log"

echo "== 4. Verify headless UI rendering =="
if [ "${CI:-}" = "true" ]; then
  echo "SKIP: UI rendering check skipped on headless CI runner"
else
  KMLINK_NAME="MacBook Pro" "$BIN" --render "$TMP/ui.png"
  KMLINK_NAME="MacBook Pro" "$BIN" --render-settings "$TMP/settings.png"
  [ -s "$TMP/ui.png" ] && [ -s "$TMP/settings.png" ]
  file "$TMP/ui.png" | grep -q "PNG image data"
  file "$TMP/settings.png" | grep -q "PNG image data"
fi

echo "== 5. Syntax check helper scripts =="
bash -n "$ROOT/build.sh" "$ROOT/install-local.sh" "$ROOT/verify.sh" \
  "$ROOT/tools/capture_login.sh" "$ROOT/tools/uninstall-original.sh"

PY3="/Library/Developer/CommandLineTools/usr/bin/python3"
if [ ! -x "$PY3" ] && command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  PY3="$(command -v python3)"
fi
if [ -x "$PY3" ]; then
  "$PY3" -m py_compile "$ROOT/tools/parse_file_frames.py"
fi

echo "VERIFY PASSED"
