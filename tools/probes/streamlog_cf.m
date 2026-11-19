// Interpose CoreFoundation stream I/O to capture OTiTransfer frames.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

static int g_fd = -1;
static CFIndex (*g_write)(CFWriteStreamRef, const UInt8 *, CFIndex);
static CFIndex (*g_read)(CFReadStreamRef, UInt8 *, CFIndex);

static void ensure_fd(void) {
    if (g_fd < 0) g_fd = open("/tmp/kmlink-cf.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void logbuf(const char *tag, const uint8_t *b, long len) {
    if (!b || len <= 0) return;
    ensure_fd();
    char line[2048];
    int n = snprintf(line, sizeof(line), "%s len=%ld ", tag, len);
    for (int i = 0; i < 32 && i < len; i++) n += snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
    if (len >= 20) {
        const uint32_t *h = (const uint32_t *)b;
        n += snprintf(line + n, sizeof(line) - n, " hdr=%u,%u,%u,%u,%u", h[0], h[1], h[2], h[3], h[4]);
    }
    n += snprintf(line + n, sizeof(line) - n, "\n");
    write(g_fd, line, n);
    for (long i = 0; i + 8 < len && i < 8192; i++) {
        if (!memcmp(b + i, "<OTIMSG>", 8) || !memcmp(b + i, "OTIMSG", 6)) {
            int m = snprintf(line, sizeof(line), "%s XML@0x%lx: ", tag, i);
            for (int j = 0; j < 900 && i + j < len; j++) {
                unsigned char c = b[i + j];
                m += snprintf(line + m, sizeof(line) - m, "%c", (c >= 32 && c < 127) ? c : '.');
            }
            m += snprintf(line + m, sizeof(line) - m, "\n");
            write(g_fd, line, m);
            break;
        }
    }
}

static CFIndex myCFWrite(CFWriteStreamRef stream, const UInt8 *buf, CFIndex len) {
    CFIndex r = g_write ? g_write(stream, buf, len) : -1;
    logbuf("W", buf, r > 0 ? (long)r : (long)len);
    return r;
}

static CFIndex myCFRead(CFReadStreamRef stream, UInt8 *buf, CFIndex len) {
    CFIndex r = g_read ? g_read(stream, buf, len) : -1;
    if (r > 0) logbuf("R", buf, (long)r);
    return r;
}

struct interpose_s { const void *new_func; const void *orig_func; };
__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_s interposes[] = {
    { (const void *)myCFWrite, (const void *)CFWriteStreamWrite },
    { (const void *)myCFRead,  (const void *)CFReadStreamRead },
};

__attribute__((constructor)) static void setup(void) {
    ensure_fd();
    void *h = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    g_write = (CFIndex (*)(CFWriteStreamRef, const UInt8 *, CFIndex))dlsym(h, "CFWriteStreamWrite");
    g_read  = (CFIndex (*)(CFReadStreamRef, UInt8 *, CFIndex))dlsym(h, "CFReadStreamRead");
    char msg[160];
    int n = snprintf(msg, sizeof(msg), "cf interpose loaded write=%p read=%p\n", (void*)g_write, (void*)g_read);
    write(g_fd, msg, n);
}
