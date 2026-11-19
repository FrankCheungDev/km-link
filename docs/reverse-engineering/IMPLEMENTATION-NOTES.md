# Implementation & Architecture Notes

Summary of verified hardware behavior, OTi USB protocol findings, and implementation choices behind the native Apple Silicon `KMLink` client.

---

## 1. Native USB Transport (`SCSITaskLib.plugin`)

- **Target device**: USB Mass Storage / HID composite bridge (`VID 0x0EA0`, `PID 0x2213`, Product `Android+Mac`).
  - Interface 0: USB Mass Storage BOT (`class 8 / subclass 6 / protocol 0x50`)
    - LUN 0: small FAT volume (`NO NAME`, vendor Windows installer)
    - **LUN 1**: virtual CD-ROM (`IOCompactDiscServices`, `MacKMLINK`) — carries the vendor SCSI tunnel
  - Interface 1: HID Mouse (4-byte relative boot-style report, no report ID)
  - Interface 2: HID Keyboard (8-byte boot keyboard report)
- **Why `SCSITaskLib.plugin` works without Rosetta or DriverKit entitlements**:
  - `IOCreatePlugInInterfaceForService` returns `kIOReturnUnsupported` on `IOCompactDiscServices`, so [`Sources/SCSITaskShim.c`](../../Sources/SCSITaskShim.c) loads Apple's built-in `SCSITaskLib.plugin` via `dlopen`, resolves `SCSITaskLibFactory`, and calls `Probe` + `Start` (opening `IOServiceOpen(..., 12, ...)`), then uses `ObtainExclusiveAccess` and `ExecuteTaskSync`.
  - Virtual media volumes must be unmounted before `ObtainExclusiveAccess`, and any existing vendor daemon (`MacKMLink` / `GoBridgeDemon`) must not hold exclusive access.

### Vendor SCSI CDBs (16-byte, trailing `4F 54` = `"OT"`)

| CDB Prefix | Purpose |
|---|---|
| `F0 00 00` | Device info / `functionType` (`buf[0x20]`, `(ft & 0x88) == 0x88` => relative HID mouse) |
| `F0 00 02` | Physical bus / speed status |
| `F0 05 02 00 0A` | USB bridge restart |
| `D8 00 03` | Remote host & RX block status poll (`0x01` = peer offline, `0x05` = RX pending, `0x07` = online) |
| `D9 28 64` | Read 64 KB OTi frame (IN) |
| `D9 2A FF` | Write 64 KB OTi frame (OUT) |
| `D9 00 33` / `D9 00 34` | Send 12-byte HID mouse / keyboard report |

---

## 2. OTi 64 KB Frame & Multi-Block Reassembly

- Fixed 64 KB (`0x10000`) block with 20-byte LE header (`[0x00..0x13]`), payload (`[0x14..]`), and 20-byte header mirror at `0xFFEC` on RX.
- Payloads larger than `0xFFD8` (65,496 B) split across multiple 64 KB blocks sharing `sequence`, with incrementing `fragmentIndex` (`[0x08..0x0B]`) and `totalFragments` (`[0x0C..0x0F]`). Implemented in `OTIFrame.encodedBlocks()` and `OTIBlockAssembler` ([`Sources/SCSITaskTransport.swift`](../../Sources/SCSITaskTransport.swift)).
- **`0x39` XML frames** carry a 4-byte `innerLen` at `0x15..0x18` (TX big-endian; RX supports both BE and LE) with the XML body starting at `0x19`.
- **Non-`0x39` binary frames** (`0x01`, `0xA1`, `0xAD`, `0xA4`, `0x10`, `0xA3`, `0x3A`, `0x37`, `0xA7`, `0xA9`) start directly at `0x15` with no 4-byte inner length.

---

## 3. Login Handshake & KM Switching

- **`0x01` LoginCommand**: Mac sends `01 10 00 00 <len> <hostname>` (note `0x10`, not `0x28`, so Windows `GO! Bridge` recognizes the peer as Mac KMLink).
- **`0xA1` ResponseResult**: 44-byte frame with `OSVERSION` TLV starting at offset 25 (`0x28` for macOS). If shifted 1 byte earlier, Windows grays out screen-edge switching options.
- **Full login response**: Mac responds to every incoming `0x01` (and fast reconnect `0xA1 cmd=0x01`) with `0xA1`, `0x01`, `0xAD` (domain folders), `0xA4` (volumes), `0xA1 cmd=0x04`, `Cmd_Post_Remote_Screen_Info`, `Cmd_Post_Remote_KM_Setting_Info` (`option=3`), and `Cmd_Get_KM_Switch_Acknowlege`.
- **Hardware HID topology**:
  - HID injection (`D9 00 33` / `D9 00 34`) is forwarded directly by bridge hardware without requiring an XML ACK from Windows.
  - Physical input devices attached to the Mac (trackpad/keyboard) must be captured via `CGEventTap` (`com.local.kmlink.eventtap` dedicated thread) and forwarded as HID packets (`Host mode`). An external mouse plugged directly into the Windows side can only drive the Mac from Windows.
  - Control return while Mac is master tracks the mirrored peer cursor position (`peerCursorX/Y`) for edge exit, alongside `⌃⌥S`.
  - macOS global `com.apple.mouse.scaling` is temporarily set to `-1` during master control and restored on exit/relaunch (`MouseScaling.swift`), while OTi virtual mouse HID acceleration defaults are preserved (`1.00×` leaves macOS defaults untouched).

---

## 4. Bidirectional Clipboard & File Shuttle

- **Text clipboard**: `0x39` XML `Cmd_Transfer_Clipboard` (`CB_Format_Text`), UTF-16LE hex payload (`CP_Content` / `CP_Content_Text`). Local `ClipboardSync` runs on a dedicated serial queue, skips `.alwaysDeny` on macOS 15.4+, and avoids echo loops.
- **Mac → Windows files**:
  - Clipboard / DropView (`sendClipboardFiles`) or active drag (`stageDragFiles`) sends `CB_Format_File` / `NodeInfoList` (824-byte `NodeInfo` entries).
  - Windows responds with `0x10` (`DownloadMultipleFile`); Mac streams `0xA3` (big-endian header) + `0x37` (file attributes) + `0xA7` (finish).
- **Windows → Mac files**:
  - Windows announces `CB_Format_File` + `NodeInfoList`.
  - Mac requests via `0x10` (`DownloadMultipleFile`, big-endian header fields with small sequential `session`/`fileID` values `101+` and UTF-16BE + NUL paths).
  - Windows replies with either `0x3A` (`MultipleFilePackage` containing LE `0xA3` + `0x37`) or standalone multi-block LE `0xA3` + standalone LE `0x37` + LE `0xA7` (observed on larger >2–4 MB files).
  - Received files save to `~/Downloads/KMLink/` and are placed on `NSPasteboard` as file URLs so `⌘V` pastes the actual file in Finder.
- **Known gaps**:
  - Windows → Mac non-ASCII filenames in clipboard file requests currently fail on the Windows peer with `ErrStr "No such file or directory"`.
  - Mac → Windows Finder cross-screen drag handoff (`Cmd_Get_Remote_Dragging_Info` + `finishLocalDragCleanly`) is implemented and covered by `--selftest`, but requires additional live desktop verification.

---

## 5. Dead Ends (Avoid Repeating)

- `IOBSDNameMatching` parent traversal (`kIOReturnUnsupported`): wrong LUN (LUN 0 vs LUN 1 `IOCompactDiscServices`).
- `IOServiceOpen` types `0–4`: must be `12` via `SCSITaskLib.plugin` `Start`.
- `USBInterfaceOpenSeize` (even as root): blocked by `IOUSBMassStorageDriver`.
- DriverKit `.dext`: requires restricted Apple USB transport entitlement & provisioning profile; unnecessary because `SCSITaskLib.plugin` works natively on `arm64`.
