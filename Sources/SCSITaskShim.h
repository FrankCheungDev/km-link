#ifndef SCSI_TASK_SHIM_H
#define SCSI_TASK_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct oti_usb oti_usb_t;

/// Opens the native arm64 SCSITask user client for the OTi bridge (`IOCompactDiscServices`).
/// Unmounts any mounted child media first, obtains exclusive access, and returns an opaque handle.
/// On failure returns NULL and writes an error code to `err_out` (if non-NULL).
oti_usb_t *oti_usb_open(int *err_out);

/// Releases exclusive access and closes the handle. Safe to pass NULL.
void oti_usb_close(oti_usb_t *h);

/// Executes the startup vendor SCSI handshake (`F0 00 02`, `F0 00 00`, `E0 15 01`).
/// Returns 0 on success.
int oti_usb_handshake(oti_usb_t *h);

/// Returns byte 0x20 of the `F0 00 00` (64B) response captured during handshake.
uint8_t oti_usb_function_type(oti_usb_t *h);

/// Sends a 12-byte HID report via vendor SCSI CDB `D9 <kind_ascii> <12B> ... 4F 54` (`dir=0`).
/// `kind_ascii`: `'3'` (0x33) mouse, `'4'` (0x34) keyboard, `'6'` (0x36) multimedia.
/// Returns 0 on success.
int oti_usb_send_hid(oti_usb_t *h, uint8_t kind_ascii, const uint8_t payload12[12]);

/// Polls bridge status (`D8 00 03 00 <tx_blocks> 7F 00 00 01 ... 4F 54`, 16B IN).
/// When `tx_blocks == 0`, `out_status[0] == 0x07` means online idle and
/// `out_status[0] == 0x05` means `out_status[2]` 64 KB blocks are ready to read.
/// Returns 0 on success.
int oti_usb_poll_status(oti_usb_t *h, uint8_t tx_blocks, uint8_t out_status[16]);

/// Reads one 64 KB OTi block (`D9 28 64 ... 4F 54`, 65536B IN).
/// Returns 0 on success.
int oti_usb_read_block64k(oti_usb_t *h, uint8_t buf[65536]);

/// Sends a single 64 KB OTi block (`D9 2A FF`, `dir=1`) without polling or trailing zero frame.
/// Returns 0 on success.
int oti_usb_send_raw_block64k(oti_usb_t *h, const uint8_t frame[65536]);

/// Reserves 2 TX blocks via `D8 00 03 00 02` and sends `frame` (64 KB) + 64 KB zero companion frame
/// via `D9 2A FF`. Returns 0 on success.
int oti_usb_write_frame64k(oti_usb_t *h, const uint8_t frame[65536]);

/// Executes an arbitrary 16-byte CDB against the exclusive SCSI task interface.
/// `dir`: 0 = none, 1 = OUT (to device), 2 = IN (from device).
/// Returns 0 on success, negative on IOKit/local error, positive on non-zero SCSI status.
int oti_usb_exec(oti_usb_t *h,
                 const uint8_t cdb[16],
                 void *buf,
                 uint32_t len,
                 uint8_t dir,
                 uint32_t timeout_ms,
                 uint8_t *scsi_status_out,
                 uint64_t *realized_out,
                 uint8_t sense_out[18]);

/// Returns the last SCSI sense buffer (18 bytes) and SCSI status recorded by `oti_usb_exec`.
void oti_usb_last_error(oti_usb_t *h,
                        int *last_kr_out,
                        uint8_t *last_status_out,
                        uint8_t sense_out[18]);

/// Adjusts IOKit HID pointer acceleration ONLY for the OTi bridge virtual mouse
/// (`VID=0x0EA0`, `PID=0x2213`, `PrimaryUsagePage=1`, `PrimaryUsage=2`).
///
/// `speed` is a multiplier relative to the macOS default for this device:
///   1.0 (or 0) => no override; the documented system defaults are restored.
///   > 1.0      => faster pointer (smaller HID acceleration value).
///   < 1.0      => slower pointer (larger HID acceleration value).
/// Lower acceleration values make THIS bridge's virtual mouse move faster, so
/// never tuning at all is the safe default. Returns the number of matching HID
/// mouse services updated (`>= 0`).
int oti_hid_tune_mouse(bool enabled, double speed, int32_t *applied_accel_out);

/// Restores the documented macOS default pointer acceleration for the OTi
/// virtual mouse. Idempotent; safe to call at start-up and on quit so a value
/// written by an earlier KMLink run cannot keep the pointer unusable.
int oti_hid_restore_mouse_defaults(int32_t *applied_accel_out);

#ifdef __cplusplus
}
#endif

#endif /* SCSI_TASK_SHIM_H */
