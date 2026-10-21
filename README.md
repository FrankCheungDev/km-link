# KMLink USB

Native Apple Silicon DriverKit transport for a vendor USB KVM / remote-access
bridge.

## Device

| Field | Value |
|---|---|
| Vendor ID | `0x0EA0` (3744) |
| Product ID | `0x2213` (8723) |
| Product string | `Android+Mac` |
| Interface | class `8`, subclass `6`, protocol `0x50` (USB Bulk-Only) |
| Bulk OUT | `0x02` |
| Bulk IN | `0x81` |

## Purpose

The bridge exchanges 64 KB frames between a Mac and a Windows host for clipboard
transfer and keyboard/mouse switching. It uses vendor-specific SCSI CDBs
(`0xD9 0x2A` outbound, `0xD9 0x28` inbound) wrapped in CBW/CSW over USB
Bulk-Only Transport.

## Architecture

- `com.kmlink.driver.usb` — DriverKit dext. Claims the vendor interface,
  performs bulk transfers and CBW/CSW handling, and exposes an `IOUserClient`.
- `com.local.kmlink` — arm64 app. Opens the dext user client and exchanges
  frames through two shared 64 KB buffers (`IOConnectMapMemory`) and
  `ExternalMethod` selectors.

The frame layout is a 64 KB buffer with a 20-byte little-endian header
(`version, sequence, flags, payload length`), a payload type byte, a 32-bit
payload length, and the uPipe XML body at offset `0x19`.

## Status

In development. The DriverKit USB transport entitlement
(`com.apple.developer.driverkit.transport.usb`) and UserClient access
(`com.apple.developer.driverkit.userclient-access`) are being requested for
local development and Developer ID distribution.

## Scope and privacy

- Communicates only with the locally attached USB device.
- No network access.
- No analytics or data collection.
- Not distributed through the Mac App Store.
