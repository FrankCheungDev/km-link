# AGENTS.md

Guidance for AI coding agents and contributors working in this repository.

## Project Overview

**KMLink** is an independent, native Apple Silicon (`arm64`) macOS client for OTi USB KVM / Data Bridge cables (`VID 0x0EA0` / `PID 0x2213`, `Android+Mac`), interoperating with the official Windows **GO! Bridge** application without Rosetta or DriverKit entitlements.

## Build & Verification

There is no `Package.swift` or `.xcodeproj`. Always build and verify with the provided scripts:

```bash
./build.sh       # Compiles Sources/SCSITaskShim.c + Sources/*.swift -> build/KMLink.app (ad-hoc signed)
./verify.sh      # Runs build.sh, codesign strict check, --selftest, UI render check, and script lint
```

- **Local Developer ID install**: `./install-local.sh` auto-detects a `Developer ID Application:` certificate from the local keychain (or takes `SIGN_IDENTITY="..."`) and installs to `/Applications/KMLink.app`.
- **Offline logic tests**: `./build/KMLink.app/Contents/MacOS/KMLink --selftest` runs 15 test suites (framing, `OTIFileTransfer`, `OTIBridge`, mock `USBLink`, `ClipboardSync`, `KMEngine` geometry). Run this after any `Sources/` change.
- **Hardware probes** (`--usbprobe`, `--hidtest`, `--switchtest`, `--kmcheck`): Require quitting any running `KMLink` or vendor `MacKMLink` / `GoBridgeDemon` instance and unmounting `/Volumes/MacKMLINK` because `ObtainExclusiveAccess` claims `IOCompactDiscServices` (LUN 1).
- **Toolchain note**: On machines where Xcode's GUI license is not accepted, `build.sh` intentionally prefers `/Library/Developer/CommandLineTools` directly to avoid Xcode license shims; on CI/Xcode hosts it falls back to `xcrun`. Keep `verify.sh` compatible with both.

## Architecture Map

- `Sources/SCSITaskShim.c` / `.h`: User-space C shim that `dlopen`s Apple's `SCSITaskLib.plugin`, calls `Probe` + `Start` (`IOServiceOpen` type `12`) on `IOCompactDiscServices`, acquires exclusive access, executes 16-byte vendor CDBs, and tunes OTi HID mouse acceleration.
- `Sources/SCSITaskTransport.swift`: Swift `OTIHIDTransport` / `OTIMultiBlockTransport` wrapper + `OTIBlockAssembler` (multi-block RX reassembly).
- `Sources/OTIFrame.swift`: 64 KB OTi frame codec, multi-block split (`encodedBlocks`), `OTISession`, `OTIXML`.
- `Sources/OTIBridge.swift` & `Sources/OTIFileTransfer.swift`: uPipe XML parsers, 824-byte `NodeInfo`, `0x10`/`0xA3`/`0x3A`/`0x37`/`0xA7`/`0xA9` codecs.
- `Sources/USBLink.swift` & `Sources/LinkNode.swift`: USB session state machine, handshake, KM forwarding, clipboard & file shuttle dispatch, and UI facade.
- `Sources/KMEngine.swift` & `Sources/MouseScaling.swift`: Dedicated-thread `CGEventTap` capture/switching and `com.apple.mouse.scaling` management.
- `Sources/Clipboard.swift`: Dedicated serial-queue `NSPasteboard` watcher and writer.
- `Sources/UI.swift`, `Sources/Settings.swift`, `Sources/main.swift`: AppKit UI, menu bar status item, CLI probes, `--selftest`, and `--render*` screenshot commands.

## Critical Invariants (Do Not Break)

1. **Keep the `SCSITaskLib.plugin` `dlopen` + `Probe`/`Start` path**: Do not revert to `IOCreatePlugInInterfaceForService` (`kIOReturnUnsupported`), `IOBSDNameMatching` on LUN 0, `IOServiceOpen` types `0–4`, `USBInterfaceOpenSeize`, or DriverKit `.dext` (see `docs/reverse-engineering/IMPLEMENTATION-NOTES.md`).
2. **Thread & AppKit isolation**: `KMEngine` runs `CGEventTap` on a dedicated high-priority thread (`com.local.kmlink.eventtap`) using CoreGraphics coordinates only — never call `NSScreen` or `NSPasteboard` inside the event tap callback. `ClipboardSync` must stay on its dedicated serial queue (`com.local.kmlink.clipboard`) and guard `NSPasteboard.accessBehavior` behind `#available(macOS 15.4, *)` + `#if compiler(>=6.1)`.
3. **OTi frame asymmetry**:
   - `0x39` XML frames include a 4-byte `innerLen` at `0x15..0x18` (BE TX; BE or LE RX) with XML starting at `0x19`; all other payload types start directly at `0x15`.
   - `0xA3` headers are **big-endian** on Mac → Windows TX and **little-endian** on Windows → Mac RX (both inside `0x3A` and standalone multi-block `0xA3`).
   - `0xA1` `OSVERSION` TLV starts at offset 25 (`0x28` for macOS), and `0x01` `LoginCommand` uses flags `0x10` so Windows recognizes the Mac peer and enables edge switching.
4. **Pointer acceleration**: Bridge virtual mouse HID acceleration (`HIDPointerAcceleration` / `HIDMouseAcceleration`) moves *faster* when values are smaller; `1.00×` must leave macOS defaults untouched and restore defaults on startup/disconnect/quit. `MouseScaling` (`com.apple.mouse.scaling = -1`) must always restore on exit and self-heal on launch.

## Repository Hygiene

- Never commit binaries, `.app` bundles, `.dylib` interposers, raw `iokitlog` captures, personal `/Users/<name>` paths, real local filenames, hardware serials, or personal Developer ID / Team IDs.
- Keep user-facing documentation updates synchronized between `README.md` (English) and `README.zh-CN.md` (Simplified Chinese).
