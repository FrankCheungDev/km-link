# Tools

Helper utilities for inspecting the OTi USB bridge, restoring virtual mouse acceleration, capturing protocol frames, and uninstalling the original vendor app.

## Active Utilities

| File | Purpose |
|---|---|
| `uninstall-original.sh` | Cleanly backs up and removes the original x86_64 `MacKMLink.app` / `GoBridgeDemon` installation and TCC entries (see `docs/UNINSTALL-ORIGINAL.md`). |
| `capture_login.sh` | Injects `iokitlog.dylib` into the original app to capture USB login frames (`0xA1` / `0xA2`). |
| `iokitlog.c` | `DYLD_INSERT_LIBRARIES` interposer for `IOConnectCallStructMethod` to dump raw CDBs and 64 KB OTi frames. |
| `parse_file_frames.py` | Parses file-shuttle frames (`0x10`, `0xA3`, `0x37`, `0xA7`, `0xA9`, XML) from an `iokitlog` capture log. |
| `scsitask_final.c` | Minimal standalone native `arm64` C proof-of-concept using `SCSITaskLib.plugin` (`Probe`/`Start` + `ObtainExclusiveAccess` + `F0 00 00`). |
| `hidprobe.c` | Lists `IOHIDEventSystemClient` services and prints OTi virtual mouse properties. |
| `hidrestore.c` | Reads or restores `HIDPointerAcceleration` / `HIDMouseAcceleration` on the OTi virtual mouse. |
| `otifunctype.c` | Queries the bridge `functionType` / identification bytes via `SCSITaskShim.c`. |

## Archived R&D Probes (`tools/probes/`)

Early investigative probes used while discovering the native `arm64` `SCSITaskLib` path and debugging frame headers (including dead-end USB seize / DriverKit / struct-patch experiments). Kept as engineering evidence and reference; not needed for building or running `KMLink.app`.
