#!/bin/bash
# Builds KMLink.app for Apple Silicon using the Command Line Tools Swift/Clang compilers
# and macOS SDK. No Xcode GUI project is required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${SDK:-}" ] && [ -z "${CLANG:-}" ] && [ -z "${SWIFTC:-}" ] \
   && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ] \
   && [ -x /Library/Developer/CommandLineTools/usr/bin/clang ] \
   && [ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]; then
  SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  CLANG="/Library/Developer/CommandLineTools/usr/bin/clang"
  SWIFTC="/Library/Developer/CommandLineTools/usr/bin/swiftc"
else
  SDK="${SDK:-$(xcrun --show-sdk-path)}"
  CLANG="${CLANG:-$(xcrun -f clang)}"
  SWIFTC="${SWIFTC:-$(xcrun -f swiftc)}"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD="$ROOT/build"
APP="$BUILD/KMLink.app"
BIN="$APP/Contents/MacOS/KMLink"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/modulecache"

echo "SDK: $SDK"
"$CLANG" \
  -target arm64-apple-macos13.0 \
  -isysroot "$SDK" \
  -O2 \
  -c "$ROOT/Sources/SCSITaskShim.c" \
  -o "$BUILD/SCSITaskShim.o"

"$SWIFTC" \
  -swift-version 5 \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$BUILD/modulecache" \
  -O \
  -import-objc-header "$ROOT/Sources/SCSITaskShim.h" \
  "$BUILD/SCSITaskShim.o" \
  "$ROOT"/Sources/*.swift \
  -o "$BIN" \
  -framework AppKit \
  -framework Carbon \
  -framework IOKit \
  -framework DiskArbitration

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 "$BIN"
chmod 644 "$APP/Contents/Info.plist" "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP" 2>/dev/null || true

if [ "$SIGN_IDENTITY" != "-" ]; then
  if codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "Signed with: $SIGN_IDENTITY (Hardened Runtime)"
  elif [ "${REQUIRE_DEV_ID:-0}" = "1" ]; then
    echo "ERROR: Failed to sign with Developer ID ($SIGN_IDENTITY)." >&2
    echo "Run from your local terminal with keychain access." >&2
    exit 1
  else
    echo "WARNING: Signing with '$SIGN_IDENTITY' unavailable; falling back to ad-hoc signature" >&2
    codesign --force --options runtime --sign - --timestamp=none "$APP"
  fi
elif [ "${REQUIRE_DEV_ID:-0}" = "1" ]; then
  echo "ERROR: SIGN_IDENTITY must be set to a Developer ID Application certificate when REQUIRE_DEV_ID=1." >&2
  exit 1
else
  codesign --force --options runtime --sign - --timestamp=none "$APP"
  echo "Signed with: ad-hoc signature (Hardened Runtime)"
fi

echo "Built: $APP"
file "$BIN"
