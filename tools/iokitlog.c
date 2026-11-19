// Interpose IOConnectCallStructMethod to log SCSITaskUserClient traffic.
// Build (x86_64):
//   clang -target x86_64-apple-macos13.0 -isysroot <SDK> -dynamiclib \
//     -framework IOKit -framework Foundation -o build/iokitlog.dylib tools/iokitlog.c
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>

static kern_return_t (*g_struct)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *);
static int g_fd = -1;
static int g_count = 0;

static void ensure_fd(void) { if (g_fd < 0) g_fd = open("/tmp/kmlink-iokit.log", O_WRONLY|O_CREAT|O_APPEND, 0644); }

static void hexline(const char *tag, const uint8_t *b, size_t n) {
    ensure_fd();
    char line[70000];
    int m = snprintf(line, sizeof(line), "%s n=%zu ", tag, n);
    size_t lim = n < 32768 ? n : 32768;
    for (size_t i = 0; i < lim; i++) m += snprintf(line+m, sizeof(line)-m, "%02x", b[i]);
    m += snprintf(line+m, sizeof(line)-m, "\n");
    write(g_fd, line, m);
}

static void dumpFrame(const char *tag, uint64_t addr, uint64_t len, size_t max) {
    if (!addr || !len) return;
    size_t n = len < max ? (size_t)len : max;
    uint8_t *buf = malloc(n);
    if (!buf) return;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)n,
                                         (vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS) got = 0;
    int dfd = open("/tmp/kmlink-dump.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (dfd >= 0) { dprintf(dfd, "dump %s addr=%llx len=%llu n=%zu\n", tag, (unsigned long long)addr, (unsigned long long)len, n); close(dfd); }
    if (got > 0) {
        hexline(tag, buf, got);
        if (got >= 0x19) {
            char line[512];
            uint8_t type = buf[0x14];
            int m = snprintf(line, sizeof(line), "FRAME type=%02x payload=", type);
            size_t start = 0x19, lim = got < 200 ? got : 200;
            for (size_t i = start; i < lim && m < (int)sizeof(line)-1; i++) {
                unsigned char c = buf[i];
                line[m++] = (c >= 32 && c < 127) ? (char)c : '.';
            }
            line[m++] = '\n';
            write(g_fd, line, m);
        }
    }
    free(buf);
}

static kern_return_t myStruct(io_connect_t conn, uint32_t sel, const void *in, size_t inCnt,
                              void *out, size_t *outCnt) {
    uint64_t dataAddr = 0, dataLen = 0;
    uint8_t dataDir = 0;
    if (sel == 6 && in && inCnt >= 59) {
        uint8_t dir; uint32_t len32; uint64_t len, addr;
        memcpy(&len32, (const uint8_t *)in + 26, 4);
        len = len32;
        dir = ((const uint8_t *)in)[34];
        memcpy(&addr, (const uint8_t *)in + 43, 8);
        dataAddr = addr; dataLen = len; dataDir = dir;
        char hdr2[192];
        int n2 = snprintf(hdr2, sizeof(hdr2), "SCSI dir=%u len=%llu addr=%llx cdb=", dir,
                          (unsigned long long)len, (unsigned long long)addr);
        for (int i = 0; i < 16; i++) n2 += snprintf(hdr2+n2, sizeof(hdr2)-n2, "%02x", ((const uint8_t *)in)[9+i]);
        n2 += snprintf(hdr2+n2, sizeof(hdr2)-n2, "\n");
        ensure_fd(); write(g_fd, hdr2, n2);
        if (dir == 1) dumpFrame("OUTDATA", addr, len, 16384);
    }
    if (g_count++ < 4000) {
        char hdr[128];
        int n = snprintf(hdr, sizeof(hdr), "CALL sel=%u in=%zu out=%zu\n", sel, inCnt,
                         outCnt ? *outCnt : 0);
        ensure_fd();
        write(g_fd, hdr, n);
        if (in && inCnt) hexline("IN", (const uint8_t *)in, inCnt);
    }
    kern_return_t r = g_struct ? g_struct(conn, sel, in, inCnt, out, outCnt) : kIOReturnError;
    if (g_count < 4000 && r == KERN_SUCCESS && out && outCnt && *outCnt) {
        hexline("OUT", (const uint8_t *)out, *outCnt);
    }
    if (dataDir == 2 && dataAddr && dataLen) dumpFrame("INDATA", dataAddr, dataLen, 16384);
    return r;
}

struct interpose_s { const void *new_func; const void *orig_func; };
__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_s interposes[] = {
    { (const void *)myStruct, (const void *)IOConnectCallStructMethod },
};

__attribute__((constructor)) static void setup(void) {
    ensure_fd();
    g_struct = (kern_return_t (*)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *))
        interposes[0].orig_func;
    if ((void *)g_struct == (void *)myStruct) g_struct = NULL;
    char msg[160];
    int n = snprintf(msg, sizeof(msg), "iokitlog loaded orig=%p self=%p\n", (void*)g_struct, (void*)myStruct);
    write(g_fd, msg, n);
}
