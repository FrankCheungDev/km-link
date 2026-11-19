// Interpose IOConnectCallStructMethod inside our own process and rewrite the
// SCSITask user-client struct version byte from 1 to 0 (the value the original
// x86_64 daemon sends). Pure user-space, no root, no Rosetta.
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

static kern_return_t (*g_orig)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *);
static int g_fd = -1;
static int g_patched = 0;

static void logline(const char *s) {
    if (g_fd < 0) g_fd = open("/tmp/scsi-patch.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (g_fd >= 0) write(g_fd, s, strlen(s));
}

static kern_return_t myStruct(io_connect_t conn, uint32_t sel, const void *in, size_t inCnt,
                              void *out, size_t *outCnt) {
    uint8_t tmp[256];
    const void *use = in;
    if (in && inCnt >= 59 && inCnt <= sizeof(tmp)) {
        memcpy(tmp, in, inCnt);
        if (tmp[23] == 0x4F && tmp[24] == 0x54) { // CDB suffix "OT" at offset 9+14
            if (tmp[0] != 0) {
                tmp[0] = 0;
                g_patched++;
                char msg[128];
                int n = snprintf(msg, sizeof(msg), "patched version sel=%u cnt=%zu total=%d\n", sel, inCnt, g_patched);
                if (n > 0) { if (g_fd < 0) g_fd = open("/tmp/scsi-patch.log", O_WRONLY|O_CREAT|O_APPEND, 0644); if (g_fd >= 0) write(g_fd, msg, n); }
            }
            use = tmp;
        }
    }
    return g_orig ? g_orig(conn, sel, use, inCnt, out, outCnt) : kIOReturnError;
}

struct interpose_s { const void *new_func; const void *orig_func; };
__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_s interposes[] = {
    { (const void *)myStruct, (const void *)IOConnectCallStructMethod },
};

__attribute__((constructor)) static void setup(void) {
    g_orig = (kern_return_t (*)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *))interposes[0].orig_func;
    if ((void *)g_orig == (void *)myStruct) g_orig = NULL;
    logline("scsi_patch loaded\n");
}
