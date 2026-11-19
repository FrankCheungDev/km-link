#!/usr/bin/env python3
"""Dump file-transfer frames from an iokitlog capture (Mac<->bridge).

Usage: tools/parse_file_frames.py [/tmp/kmlink-iokit.log]

Prints every command / data frame that belongs to the file shuttle protocol
(0x10 download request, 0xa3 file data, 0x37 attributes, 0xa7 finish, 0xa9
errors) plus any XML frame that mentions files or NodeInfo, in capture order.
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/kmlink-iokit.log"
INTERESTING = {0x10, 0x37, 0xA3, 0xA7, 0xA9}

with open(path, errors="ignore") as fh:
    for line in fh:
        m = re.match(r"(IN|OUT) ?DATA n=(\d+) ([0-9a-f]+)", line) or \
            re.match(r"(INDATA|OUTDATA) n=(\d+) ([0-9a-f]+)", line)
        if not m:
            continue
        direction = "WIN->MAC" if m.group(1).startswith("IN") else "MAC->WIN"
        blob = bytes.fromhex(m.group(3))
        if len(blob) <= 0x14:
            continue
        ftype = blob[0x14]
        plen = int.from_bytes(blob[0x10:0x14], "little")
        body = blob[0x14:]
        if ftype == 0x39:
            text = blob[0x19:0x19 + plen if plen else len(blob)].decode("utf-8", "replace")
            if not re.search(r"File|NodeInfo|Clipboard|Drag", text):
                continue
            cmd = re.search(r"<NP_Cmd>([^<]+)</NP_Cmd>", text)
            print(f"[{direction}] XML type=0x39 cmd={cmd.group(1) if cmd else '?'} len={len(text)}")
            print("   " + text[:900].replace("\n", " "))
        elif ftype in INTERESTING:
            print(f"[{direction}] type=0x{ftype:02x} payloadLen={plen} hashes={body[:24].hex()}")
