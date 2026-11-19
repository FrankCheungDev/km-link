#include "SCSITaskShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/scsi/SCSITask.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define OTI_SCSITASK_PLUGIN_PATH \
    "/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext" \
    "/Contents/PlugIns/SCSITaskUserClient.kext" \
    "/Contents/PlugIns/SCSITaskLib.plugin/Contents/MacOS/SCSITaskLib"

typedef void *(*SCSITaskFactoryFn)(void *allocator, CFUUIDRef typeUUID);

struct oti_usb {
    void *dl_handle;
    io_service_t service;
    IOCFPlugInInterface **plugin;
    SCSITaskDeviceInterface **dev;
    SCSITaskInterface **task;
    bool has_exclusive;
    uint8_t function_type;
    int last_kr;
    int last_srv_resp;
    uint8_t last_status;
    uint8_t last_sense[18];
};

static pthread_mutex_t oti_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void oti_scsi_log(const char *fmt, ...) {
    const char *path = "/tmp/kmlink-scsi.log";
    pthread_mutex_lock(&oti_log_lock);
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size >= 2 * 1024 * 1024) {
        rename(path, "/tmp/kmlink-scsi.log.1");
    }
    FILE *fp = fopen(path, "a");
    if (!fp) {
        pthread_mutex_unlock(&oti_log_lock);
        return;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm_now;
    localtime_r(&ts.tv_sec, &tm_now);
    fprintf(fp, "[%02d:%02d:%02d.%03ld] ",
            tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec, ts.tv_nsec / 1000000L);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fp, fmt, ap);
    va_end(ap);
    fputc('\n', fp);
    fclose(fp);
    pthread_mutex_unlock(&oti_log_lock);
}

static void oti_format_hex(const uint8_t *buf, size_t n, char *out, size_t out_sz) {
    size_t pos = 0;
    for (size_t i = 0; i < n && pos + 3 < out_sz; i++) {
        pos += (size_t)snprintf(out + pos, out_sz - pos, "%02x", buf[i]);
    }
    if (pos < out_sz) out[pos] = '\0';
}

static void oti_extract_cmd_preview(const uint8_t *buf, uint32_t len, char *out, size_t out_sz) {
    out[0] = '\0';
    if (!buf || len < 0x19) return;
    if (buf[0x14] != 0x39) {
        snprintf(out, out_sz, "type=0x%02x", buf[0x14]);
        return;
    }
    size_t scan_len = len > 512 ? 512 : len;
    const char *needle = "<NP_Cmd>";
    for (size_t i = 0x19; i + 8 < scan_len; i++) {
        if (memcmp(buf + i, needle, 8) == 0) {
            size_t start = i + 8;
            size_t j = 0;
            while (start + j < scan_len && buf[start + j] != '<' && j + 1 < out_sz) {
                out[j] = (char)buf[start + j];
                j++;
            }
            out[j] = '\0';
            return;
        }
    }
    snprintf(out, out_sz, "type=0x39");
}

typedef struct {
    volatile int done;
} da_unmount_ctx_t;

static void da_unmount_cb(DADiskRef disk, DADissenterRef dissenter, void *context) {
    (void)disk;
    (void)dissenter;
    da_unmount_ctx_t *ctx = (da_unmount_ctx_t *)context;
    if (ctx) {
        ctx->done = 1;
    }
}

static void unmount_bsd_name(DASessionRef session, const char *bsd) {
    if (!session || !bsd || !bsd[0]) return;
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd);
    if (!disk) return;
    da_unmount_ctx_t ctx = { 0 };
    DADiskUnmount(disk, kDADiskUnmountOptionForce, da_unmount_cb, &ctx);
    for (int i = 0; i < 30 && !ctx.done; i++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }
    CFRelease(disk);
}

static void oti_unmount_media(io_service_t svc) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return;
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    if (svc != IO_OBJECT_NULL) {
        CFTypeRef bsdProp = IORegistryEntrySearchCFProperty(
            svc,
            kIOServicePlane,
            CFSTR("BSD Name"),
            kCFAllocatorDefault,
            kIORegistryIterateRecursively);
        if (bsdProp) {
            if (CFGetTypeID(bsdProp) == CFStringGetTypeID()) {
                char bsd[64] = { 0 };
                if (CFStringGetCString((CFStringRef)bsdProp, bsd, sizeof(bsd), kCFStringEncodingUTF8)) {
                    unmount_bsd_name(session, bsd);
                }
            }
            CFRelease(bsdProp);
        }
    }

    // Fallback names used by the dual-LUN OTi bridge (disk5s0 CDROM + disk4 FAT).
    const char *fallbacks[] = { "disk5s0", "disk5", "disk4" };
    for (size_t i = 0; i < sizeof(fallbacks) / sizeof(fallbacks[0]); i++) {
        unmount_bsd_name(session, fallbacks[i]);
    }

    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);
}

static int prop_matches_int(io_service_t svc, CFStringRef key, int expected) {
    CFTypeRef prop = IORegistryEntrySearchCFProperty(
        svc,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateParents | kIORegistryIterateRecursively);
    if (!prop) return 0;
    int matched = 0;
    if (CFGetTypeID(prop) == CFNumberGetTypeID()) {
        int val = 0;
        if (CFNumberGetValue((CFNumberRef)prop, kCFNumberIntType, &val)) {
            matched = (val == expected);
        }
    }
    CFRelease(prop);
    return matched;
}

static io_service_t find_oti_cd_service(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOCompactDiscServices");
    if (!matching) return IO_OBJECT_NULL;
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_service_t first = IO_OBJECT_NULL;
    io_service_t chosen = IO_OBJECT_NULL;
    io_service_t cand = IO_OBJECT_NULL;
    while ((cand = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        if (first == IO_OBJECT_NULL) {
            first = cand;
            IOObjectRetain(first);
        }
        if (prop_matches_int(cand, CFSTR("idVendor"), 0x0EA0) &&
            prop_matches_int(cand, CFSTR("idProduct"), 0x2213)) {
            chosen = cand;
            break;
        }
        IOObjectRelease(cand);
    }
    IOObjectRelease(iter);

    if (chosen != IO_OBJECT_NULL) {
        if (first != IO_OBJECT_NULL) IOObjectRelease(first);
        return chosen;
    }
    return first;
}

oti_usb_t *oti_usb_open(int *err_out) {
    if (err_out) *err_out = 0;

    void *dl_handle = dlopen(OTI_SCSITASK_PLUGIN_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!dl_handle) {
        if (err_out) *err_out = -1;
        return NULL;
    }

    SCSITaskFactoryFn factory = (SCSITaskFactoryFn)dlsym(dl_handle, "SCSITaskLibFactory");
    if (!factory) {
        dlclose(dl_handle);
        if (err_out) *err_out = -2;
        return NULL;
    }

    io_service_t svc = find_oti_cd_service();
    if (svc == IO_OBJECT_NULL) {
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kIOReturnNotFound;
        return NULL;
    }

    oti_unmount_media(svc);

    IOCFPlugInInterface **plugin =
        (IOCFPlugInInterface **)factory(NULL, kIOSCSITaskDeviceUserClientTypeID);
    if (!plugin) {
        IOObjectRelease(svc);
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kIOReturnNoResources;
        return NULL;
    }

    SInt32 score = 0;
    (void)(*plugin)->Probe(plugin, NULL, svc, &score);
    IOReturn kr = (*plugin)->Start(plugin, NULL, svc);
    if (kr != kIOReturnSuccess) {
        (*plugin)->Release(plugin);
        IOObjectRelease(svc);
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kr;
        return NULL;
    }

    SCSITaskDeviceInterface **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
        (LPVOID *)&dev);
    if (hr != S_OK || !dev) {
        (*plugin)->Stop(plugin);
        (*plugin)->Release(plugin);
        IOObjectRelease(svc);
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kIOReturnNoDevice;
        return NULL;
    }

    kr = (*dev)->ObtainExclusiveAccess(dev);
    if (kr != kIOReturnSuccess) {
        // Retry once after an additional unmount attempt in case media remounted.
        oti_unmount_media(svc);
        kr = (*dev)->ObtainExclusiveAccess(dev);
    }
    if (kr != kIOReturnSuccess) {
        (*dev)->Release(dev);
        (*plugin)->Stop(plugin);
        (*plugin)->Release(plugin);
        IOObjectRelease(svc);
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kr;
        return NULL;
    }

    oti_usb_t *h = (oti_usb_t *)calloc(1, sizeof(oti_usb_t));
    if (!h) {
        (*dev)->ReleaseExclusiveAccess(dev);
        (*dev)->Release(dev);
        (*plugin)->Stop(plugin);
        (*plugin)->Release(plugin);
        IOObjectRelease(svc);
        dlclose(dl_handle);
        if (err_out) *err_out = (int)kIOReturnNoMemory;
        return NULL;
    }

    h->dl_handle = dl_handle;
    h->service = svc;
    h->plugin = plugin;
    h->dev = dev;
    h->task = (*dev)->CreateSCSITask(dev);
    h->has_exclusive = true;
    oti_scsi_log("open ok svc=0x%x task=%p", (unsigned int)svc, (void *)h->task);
    return h;
}

void oti_usb_close(oti_usb_t *h) {
    if (!h) return;
    oti_scsi_log("close svc=0x%x", (unsigned int)h->service);
    if (h->task) {
        (*h->task)->Release(h->task);
        h->task = NULL;
    }
    if (h->dev) {
        if (h->has_exclusive) {
            (*h->dev)->ReleaseExclusiveAccess(h->dev);
            h->has_exclusive = false;
        }
        (*h->dev)->Release(h->dev);
        h->dev = NULL;
    }
    if (h->plugin) {
        (*h->plugin)->Stop(h->plugin);
        (*h->plugin)->Release(h->plugin);
        h->plugin = NULL;
    }
    if (h->service != IO_OBJECT_NULL) {
        IOObjectRelease(h->service);
        h->service = IO_OBJECT_NULL;
    }
    if (h->dl_handle) {
        dlclose(h->dl_handle);
        h->dl_handle = NULL;
    }
    free(h);
}

int oti_usb_exec(oti_usb_t *h,
                 const uint8_t cdb[16],
                 void *buf,
                 uint32_t len,
                 uint8_t dir,
                 uint32_t timeout_ms,
                 uint8_t *scsi_status_out,
                 uint64_t *realized_out,
                 uint8_t sense_out[18]) {
    if (!h || !h->dev || !cdb) return (int)kIOReturnBadArgument;

    SCSITaskInterface **task = h->task;
    if (task) {
        IOReturn reset_kr = (*task)->ResetForNewTask(task);
        if (reset_kr != kIOReturnSuccess) {
            (*task)->Release(task);
            h->task = NULL;
            task = NULL;
        }
    }
    if (!task) {
        task = (*h->dev)->CreateSCSITask(h->dev);
        h->task = task;
    }
    if (!task) {
        h->last_kr = (int)kIOReturnNoResources;
        h->last_srv_resp = -1;
        oti_scsi_log("exec CreateSCSITask failed cdb=%02x%02x%02x", cdb[0], cdb[1], cdb[2]);
        return h->last_kr;
    }

    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0;
    SCSIServiceResponse srv_resp = kSCSIServiceResponse_Request_In_Process;
    UInt64 realized = 0;

    IOReturn kr = (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    if (kr == kIOReturnSuccess && len > 0 && dir != 0) {
        if (!buf) {
            return (int)kIOReturnBadArgument;
        }
        SCSITaskSGElement sg = { (uintptr_t)buf, len };
        UInt8 scsi_dir = (dir == 1)
            ? kSCSIDataTransfer_FromInitiatorToTarget
            : kSCSIDataTransfer_FromTargetToInitiator;
        kr = (*task)->SetScatterGatherEntries(task, &sg, 1, len, scsi_dir);
    } else if (kr == kIOReturnSuccess) {
        kr = (*task)->SetScatterGatherEntries(task, NULL, 0, 0, kSCSIDataTransfer_NoDataTransfer);
    }

    if (kr == kIOReturnSuccess) {
        (*task)->SetTimeoutDuration(task, timeout_ms ? timeout_ms : 2000);
        kr = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
        if (kr == kIOReturnSuccess) {
            (void)(*task)->GetSCSIServiceResponse(task, &srv_resp);
        }
    }

    if (kr != kIOReturnSuccess || srv_resp != kSCSIServiceResponse_TASK_COMPLETE || status != 0) {
        (*task)->Release(task);
        h->task = NULL;
    }

    h->last_kr = (int)kr;
    h->last_srv_resp = (int)srv_resp;
    h->last_status = (uint8_t)status;
    memset(h->last_sense, 0, sizeof(h->last_sense));
    size_t copy_len = sizeof(sense) < sizeof(h->last_sense) ? sizeof(sense) : sizeof(h->last_sense);
    memcpy(h->last_sense, &sense, copy_len);

    if (scsi_status_out) *scsi_status_out = (uint8_t)status;
    if (realized_out) *realized_out = (uint64_t)realized;
    if (sense_out) {
        memset(sense_out, 0, 18);
        memcpy(sense_out, h->last_sense, sizeof(h->last_sense));
    }

    int rc = 0;
    if (kr != kIOReturnSuccess) {
        rc = (int)kr;
    } else if (srv_resp != kSCSIServiceResponse_TASK_COMPLETE) {
        rc = (status != 0) ? (int)status : -(100 + (int)srv_resp);
    } else if (status != 0) {
        rc = (int)status;
    } else if (len > 0 && realized != (UInt64)len) {
        rc = (int)kIOReturnUnderrun;
    }

    bool is_poll = (cdb[0] == 0xD8 && cdb[2] == 0x03);
    bool is_hid = (cdb[0] == 0xD9 && (cdb[1] == 0x33 || cdb[1] == 0x34 || cdb[1] == 0x36));
    bool is_interesting_poll = is_poll && (cdb[4] != 0 || ((const uint8_t *)buf)[0] != 0x07 || rc != 0);
    if ((!is_poll || is_interesting_poll) && (!is_hid || rc != 0)) {
        char sense_hex[40];
        oti_format_hex(h->last_sense, 18, sense_hex, sizeof(sense_hex));
        if (cdb[0] == 0xD9 && cdb[1] == 0x2A && buf && len >= 0x19) {
            char hdr_hex[64];
            char preview[96];
            oti_format_hex((const uint8_t *)buf, 28, hdr_hex, sizeof(hdr_hex));
            oti_extract_cmd_preview((const uint8_t *)buf, len, preview, sizeof(preview));
            oti_scsi_log("TX D92A rc=%d kr=0x%x srv=%d st=%u realized=%llu hdr=%s %s sense=%s",
                         rc, (unsigned int)kr, (int)srv_resp, (unsigned int)status,
                         (unsigned long long)realized, hdr_hex, preview, sense_hex);
        } else if (cdb[0] == 0xD9 && cdb[1] == 0x28 && buf && len >= 0x19) {
            const uint8_t *b = (const uint8_t *)buf;
            char hdr_hex[64];
            char preview[96];
            oti_format_hex(b, 28, hdr_hex, sizeof(hdr_hex));
            oti_extract_cmd_preview(b, len, preview, sizeof(preview));
            oti_scsi_log("RX D928 rc=%d kr=0x%x srv=%d st=%u realized=%llu hdr=%s %s sense=%s",
                         rc, (unsigned int)kr, (int)srv_resp, (unsigned int)status,
                         (unsigned long long)realized, hdr_hex, preview, sense_hex);
            if (rc == 0 && b[12] == 1 && b[0x14] != 0) {
                uint32_t plen = (uint32_t)b[16] | ((uint32_t)b[17] << 8)
                              | ((uint32_t)b[18] << 16) | ((uint32_t)b[19] << 24);
                if (b[0x14] == 0x39 && plen > 5) {
                    size_t avail = (len > 0x19) ? (len - 0x19) : 0;
                    size_t xlen = (size_t)(plen - 5);
                    if (xlen > avail) xlen = avail;
                    if (xlen > 2048) xlen = 2048;
                    size_t off = 0;
                    while (off < xlen) {
                        char chunk[221];
                        size_t n = xlen - off;
                        if (n > 220) n = 220;
                        for (size_t i = 0; i < n; i++) {
                            uint8_t ch = b[0x19 + off + i];
                            chunk[i] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '.';
                        }
                        chunk[n] = '\0';
                        oti_scsi_log("RX XML [%zu/%zu]: %s", off, xlen, chunk);
                        off += n;
                    }
                } else {
                    size_t rlen = (size_t)plen;
                    size_t avail = (len > 0x14) ? (len - 0x14) : 0;
                    if (rlen > avail) rlen = avail;
                    if (rlen > 64) rlen = 64;
                    char raw_hex[132];
                    oti_format_hex(b + 0x14, rlen, raw_hex, sizeof(raw_hex));
                    oti_scsi_log("RX RAW type=0x%02x plen=%u hex=%s",
                                 (unsigned int)b[0x14], (unsigned int)plen, raw_hex);
                }
            }
        } else if (is_poll && buf && len >= 16) {
            char st_hex[40];
            oti_format_hex((const uint8_t *)buf, 16, st_hex, sizeof(st_hex));
            oti_scsi_log("POLL tx=%u rc=%d kr=0x%x srv=%d st=%u realized=%llu data=%s sense=%s",
                         (unsigned int)cdb[4], rc, (unsigned int)kr, (int)srv_resp,
                         (unsigned int)status, (unsigned long long)realized, st_hex, sense_hex);
        } else {
            oti_scsi_log("CDB %02x%02x%02x dir=%u len=%u rc=%d kr=0x%x srv=%d st=%u realized=%llu sense=%s",
                         cdb[0], cdb[1], cdb[2], (unsigned int)dir, (unsigned int)len,
                         rc, (unsigned int)kr, (int)srv_resp, (unsigned int)status,
                         (unsigned long long)realized, sense_hex);
        }
    }

    return rc;
}

void oti_usb_last_error(oti_usb_t *h,
                        int *last_kr_out,
                        uint8_t *last_status_out,
                        uint8_t sense_out[18]) {
    if (!h) return;
    if (last_kr_out) *last_kr_out = h->last_kr;
    if (last_status_out) *last_status_out = h->last_status;
    if (sense_out) memcpy(sense_out, h->last_sense, 18);
}

int oti_usb_handshake(oti_usb_t *h) {
    if (!h) return (int)kIOReturnBadArgument;

    uint8_t buf[512];
    const uint8_t cdb_bus[16] = { 0xF0, 0x00, 0x02, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54 };
    const uint8_t cdb_ver[16] = { 0xF0, 0x00, 0x00, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54 };
    const uint8_t cdb_lic[16] = { 0xE0, 0x15, 0x01, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54 };

    memset(buf, 0, 64);
    int r = oti_usb_exec(h, cdb_bus, buf, 64, 2, 2000, NULL, NULL, NULL);
    if (r != 0) return r;

    memset(buf, 0, 12);
    r = oti_usb_exec(h, cdb_ver, buf, 12, 2, 2000, NULL, NULL, NULL);
    if (r != 0) return r;

    memset(buf, 0, 64);
    r = oti_usb_exec(h, cdb_ver, buf, 64, 2, 2000, NULL, NULL, NULL);
    if (r != 0) return r;
    h->function_type = buf[0x20];
    oti_scsi_log("handshake function_type=0x%02x", (unsigned int)h->function_type);

    memset(buf, 0, 512);
    r = oti_usb_exec(h, cdb_lic, buf, 512, 2, 2000, NULL, NULL, NULL);
    return r;
}

uint8_t oti_usb_function_type(oti_usb_t *h) {
    return h ? h->function_type : 0;
}

int oti_usb_send_hid(oti_usb_t *h, uint8_t kind_ascii, const uint8_t payload12[12]) {
    if (!h || !payload12) return (int)kIOReturnBadArgument;
    uint8_t cdb[16];
    cdb[0] = 0xD9;
    cdb[1] = kind_ascii;
    memcpy(cdb + 2, payload12, 12);
    cdb[14] = 0x4F;
    cdb[15] = 0x54;
    return oti_usb_exec(h, cdb, NULL, 0, 0, 1000, NULL, NULL, NULL);
}

int oti_usb_poll_status(oti_usb_t *h, uint8_t tx_blocks, uint8_t out_status[16]) {
    if (!h || !out_status) return (int)kIOReturnBadArgument;
    uint8_t cdb[16] = {
        0xD8, 0x00, 0x03, 0x00, tx_blocks, 0x7F, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00,      0x00, 0x4F, 0x54
    };
    memset(out_status, 0, 16);
    return oti_usb_exec(h, cdb, out_status, 16, 2, 2000, NULL, NULL, NULL);
}

int oti_usb_read_block64k(oti_usb_t *h, uint8_t buf[65536]) {
    if (!h || !buf) return (int)kIOReturnBadArgument;
    const uint8_t cdb[16] = {
        0xD9, 0x28, 0x64, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54
    };
    memset(buf, 0, 65536);
    return oti_usb_exec(h, cdb, buf, 65536, 2, 2000, NULL, NULL, NULL);
}

int oti_usb_send_raw_block64k(oti_usb_t *h, const uint8_t frame[65536]) {
    if (!h || !frame) return (int)kIOReturnBadArgument;
    const uint8_t cdb_put[16] = {
        0xD9, 0x2A, 0xFF, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54
    };
    uint8_t *tx_buf = (uint8_t *)malloc(65536);
    if (!tx_buf) return (int)kIOReturnNoMemory;
    memcpy(tx_buf, frame, 65536);
    int r = oti_usb_exec(h, cdb_put, tx_buf, 65536, 1, 2000, NULL, NULL, NULL);
    free(tx_buf);
    return r;
}

int oti_usb_write_frame64k(oti_usb_t *h, const uint8_t frame[65536]) {
    if (!h || !frame) return (int)kIOReturnBadArgument;

    uint8_t st[16];
    int r = -1;
    for (int attempt = 0; attempt < 20; attempt++) {
        r = oti_usb_poll_status(h, 0x02, st);
        if (r == 0 && (st[0] == 0x07 || st[0] == 0x06)) break;
        usleep(5000);
    }
    if (r != 0) return r;

    r = oti_usb_send_raw_block64k(h, frame);
    if (r == 0) {
        uint8_t *zero_buf = (uint8_t *)calloc(1, 65536);
        if (!zero_buf) return (int)kIOReturnNoMemory;
        r = oti_usb_send_raw_block64k(h, zero_buf);
        free(zero_buf);
    }
    return r;
}

static bool cf_number_equals_int32(CFTypeRef val, int32_t expected) {
    if (!val || CFGetTypeID(val) != CFNumberGetTypeID()) return false;
    int32_t out = 0;
    if (!CFNumberGetValue((CFNumberRef)val, kCFNumberSInt32Type, &out)) return false;
    return out == expected;
}

static bool hid_service_copy_int32(IOHIDServiceClientRef svc, CFStringRef key, int32_t *out) {
    CFTypeRef val = IOHIDServiceClientCopyProperty(svc, key);
    if (!val) return false;
    bool ok = false;
    if (CFGetTypeID(val) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)val, kCFNumberSInt32Type, out);
    }
    CFRelease(val);
    return ok;
}

/*
 * Native macOS HID pointer acceleration keys are 16.16 fixed-point multipliers
 * applied to the device's relative reports. Observed system defaults (Apple's
 * own HID services and this bridge's untouched keyboard service):
 *
 *   HIDPointerAcceleration = 45056 (0.6875)
 *   HIDMouseAcceleration   = 32768 (0.5)
 *
 * LOWER values make the OTi virtual mouse move FASTER on this bridge; writing
 * a value far below the default (an earlier revision used 6144) produced the
 * "insanely fast / uncontrollable pointer" regression reported on macOS 26.
 * Never go below the system default unless the caller explicitly asks for a
 * faster pointer, and always restore the defaults when we stop overriding.
 */
#define OTI_HID_DEFAULT_POINTER_ACCEL 45056
#define OTI_HID_DEFAULT_MOUSE_ACCEL 32768
#define OTI_HID_MIN_ACCEL 4096
#define OTI_HID_MAX_ACCEL 262144

static int32_t oti_hid_accel_for_speed(int32_t base, double speed) {
    if (!(speed > 0.0)) return base;
    /* speed > 1.0 => faster pointer => smaller acceleration value. */
    double scaled = (double)base / speed;
    if (scaled < (double)OTI_HID_MIN_ACCEL) scaled = (double)OTI_HID_MIN_ACCEL;
    if (scaled > (double)OTI_HID_MAX_ACCEL) scaled = (double)OTI_HID_MAX_ACCEL;
    return (int32_t)(scaled + 0.5);
}

static bool oti_hid_speed_is_neutral(double speed) {
    return !(speed > 0.0) || (speed > 0.995 && speed < 1.005);
}

int oti_hid_tune_mouse(bool enabled, double speed, int32_t *applied_accel_out) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) return 0;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) {
        CFRelease(client);
        return 0;
    }

    bool neutral = oti_hid_speed_is_neutral(speed);
    bool apply = enabled && !neutral;
    int32_t pointer_accel = apply ? oti_hid_accel_for_speed(OTI_HID_DEFAULT_POINTER_ACCEL, speed)
                                  : OTI_HID_DEFAULT_POINTER_ACCEL;
    int32_t mouse_accel = apply ? oti_hid_accel_for_speed(OTI_HID_DEFAULT_MOUSE_ACCEL, speed)
                                : OTI_HID_DEFAULT_MOUSE_ACCEL;
    if (applied_accel_out) {
        *applied_accel_out = apply ? mouse_accel : OTI_HID_DEFAULT_MOUSE_ACCEL;
    }

    int updated = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!svc) continue;
        CFTypeRef vid = IOHIDServiceClientCopyProperty(svc, CFSTR("VendorID"));
        CFTypeRef pid = IOHIDServiceClientCopyProperty(svc, CFSTR("ProductID"));
        CFTypeRef upg = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
        CFTypeRef usg = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
        bool match = cf_number_equals_int32(vid, 0x0EA0)
                  && cf_number_equals_int32(pid, 0x2213)
                  && cf_number_equals_int32(upg, 1)
                  && cf_number_equals_int32(usg, 2);
        if (vid) CFRelease(vid);
        if (pid) CFRelease(pid);
        if (upg) CFRelease(upg);
        if (usg) CFRelease(usg);
        if (!match) continue;

        int32_t current_ptr = OTI_HID_DEFAULT_POINTER_ACCEL;
        int32_t current_mse = OTI_HID_DEFAULT_MOUSE_ACCEL;
        bool have_ptr = hid_service_copy_int32(svc, CFSTR(kIOHIDPointerAccelerationKey), &current_ptr);
        bool have_mse = hid_service_copy_int32(svc, CFSTR(kIOHIDMouseAccelerationTypeKey), &current_mse);
        if (!apply && (!have_ptr || !have_mse ||
                       (current_ptr == pointer_accel && current_mse == mouse_accel))) {
            /* Already at the documented defaults; nothing to restore. */
            continue;
        }

        CFNumberRef ptr_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pointer_accel);
        CFNumberRef mse_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &mouse_accel);
        if (ptr_num) {
            IOHIDServiceClientSetProperty(svc, CFSTR(kIOHIDPointerAccelerationKey), ptr_num);
            CFRelease(ptr_num);
        }
        if (mse_num) {
            IOHIDServiceClientSetProperty(svc, CFSTR(kIOHIDMouseAccelerationTypeKey), mse_num);
            CFRelease(mse_num);
        }
        oti_scsi_log("HID mouse %s: pointer %d -> %d, mouse %d -> %d (speed %.2fx)",
                     apply ? "tuned" : "restored",
                     (int)current_ptr, (int)pointer_accel,
                     (int)current_mse, (int)mouse_accel,
                     speed);
        updated++;
    }

    CFRelease(services);
    CFRelease(client);
    return updated;
}

int oti_hid_restore_mouse_defaults(int32_t *applied_accel_out) {
    return oti_hid_tune_mouse(false, 1.0, applied_accel_out);
}
