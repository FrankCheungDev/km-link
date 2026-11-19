#!/bin/bash
# Captures the original MacKMLink login frames (0xA1 34B cmd=0x04 and 0xA2 563B)
# by injecting tools/iokitlog.c into GoBridgeDemon via the original app.
#
# Preconditions:
#   * the bridge was just re-plugged, so /Volumes/MacKMLINK exists and no
#     SCSITask client has touched the device yet (our own tools drop the
#     storage interfaces until the next re-plug);
#   * KMLink.app is NOT running;
#   * Accessibility is granted to .../GoBridgeDemon.app.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/kmlink-iokit.log
OUT=/tmp/mackmlink-capture.out
SECS="${1:-50}"

# Our own SCSITask client hides the bridge volumes until the device is
# re-plugged, so KMLink must be stopped *and* the cable re-plugged.
pkill -f "KMLink.app/Contents/MacOS/KMLink" 2>/dev/null
pkill -f "MacKMLink.app/Contents/MacOS/MacKMLink" 2>/dev/null
pkill -f GoBridgeDemon 2>/dev/null
sleep 1

if [ ! -d /Volumes/MacKMLINK ]; then
    echo "KMLink 已退出。现在请【重新拔插桥接线的 Mac 端】..."
    for i in $(seq 1 90); do
        [ -d /Volumes/MacKMLINK ] && break
        sleep 1
    done
fi

if [ ! -d /Volumes/MacKMLINK ]; then
    echo "BIED: 等不到 /Volumes/MacKMLINK —— 请确认桥接线已插好（桌面上应出现 MacKMLINK 卷）"
    exit 2
fi
echo "卷已就绪，开始抓包..."
rm -f "$LOG" "$OUT"

APP="${APP:-$HOME/Library/MacKMLinkFull/MacKMLink.app}"
if [ -x /Applications/MacKMLink.app/Contents/MacOS/MacKMLink ]; then
    APP="${APP_OVERRIDE:-/Applications/MacKMLink.app}"
fi
echo "using app: $APP"
DYLD_INSERT_LIBRARIES="$ROOT/build/iokitlog.dylib" \
    "$APP/Contents/MacOS/MacKMLink" >"$OUT" 2>&1 &
sleep "$SECS"
pkill -f "MacKMLink.app/Contents/MacOS/MacKMLink" 2>/dev/null
pkill -f GoBridgeDemon 2>/dev/null

echo "== AX / daemon =="
grep -oE "enableAccessibility = [01]" "$OUT" | sort | uniq -c
grep -cE "gesture event tap failed" "$OUT"

echo "== SCSITask calls =="
grep -c "^CALL sel=6" "$LOG" 2>/dev/null

python3 - "$LOG" <<'PY'
import re, sys
path = sys.argv[1]
found = {}
try:
    fh = open(path, errors='ignore')
except FileNotFoundError:
    print("no iokit log")
    raise SystemExit
for line in fh:
    m = re.match(r'OUTDATA n=(\d+) ([0-9a-f]+)', line)
    if not m:
        continue
    b = bytes.fromhex(m.group(2))
    if len(b) <= 0x14:
        continue
    t = b[0x14]
    plen = int.from_bytes(b[0x10:0x14], 'little')
    payload = b[0x19:0x19 + plen] if plen else b[0x19:]
    print(f"frame type=0x{t:02x} payloadLen={plen} dumped={len(b)} seq={int.from_bytes(b[0:4],'little')}")
    if t in (0xA1, 0xA2) and t not in found:
        found[t] = payload
for t, p in sorted(found.items()):
    print(f"\n===== type=0x{t:02x} ({len(p)} bytes) =====")
    print(p.hex())
PY
