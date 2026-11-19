// Inject into MacKMLink/GoBridgeDemon to log the OTiTransfer byte stream.
// Build: clang -target x86_64-apple-macos13.0 -dynamiclib -framework Foundation \
//        -o build/streamlog.dylib tools/streamlog.m
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

static IMP g_origWrite;
static IMP g_origRead;
static int g_fd = -1;

static void ensure_fd(void) {
    if (g_fd < 0) g_fd = open("/tmp/kmlink-stream.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void logbuf(const char *tag, const uint8_t *b, long len) {
    if (!b || len <= 0) return;
    ensure_fd();
    char line[1024];
    int n = snprintf(line, sizeof(line), "%s len=%ld ", tag, len);
    for (int i = 0; i < 32 && i < len; i++) n += snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
    if (len >= 20) {
        const uint32_t *h = (const uint32_t *)b;
        n += snprintf(line + n, sizeof(line) - n, " hdr=%u,%u,%u,%u,%u", h[0], h[1], h[2], h[3], h[4]);
    }
    n += snprintf(line + n, sizeof(line) - n, "\n");
    write(g_fd, line, n);

    for (long i = 0; i + 8 < len && i < 4096; i++) {
        if (!memcmp(b + i, "<OTIMSG>", 8) || !memcmp(b + i, "OTIMSG", 6)) {
            int m = snprintf(line, sizeof(line), "%s XML@0x%lx: ", tag, i);
            for (int j = 0; j < 600 && i + j < len; j++) {
                unsigned char c = b[i + j];
                m += snprintf(line + m, sizeof(line) - m, "%c", (c >= 32 && c < 127) ? c : '.');
            }
            m += snprintf(line + m, sizeof(line) - m, "\n");
            write(g_fd, line, m);
            break;
        }
    }
}

static NSInteger myWrite(id self, SEL _cmd, const uint8_t *buf, NSInteger len) {
    logbuf("W", buf, (long)len);
    return ((NSInteger (*)(id, SEL, const uint8_t *, NSInteger))g_origWrite)(self, _cmd, buf, len);
}

static NSInteger myRead(id self, SEL _cmd, uint8_t *buf, NSInteger len) {
    NSInteger r = ((NSInteger (*)(id, SEL, uint8_t *, NSInteger))g_origRead)(self, _cmd, buf, len);
    if (r > 0) logbuf("R", buf, (long)r);
    return r;
}

__attribute__((constructor)) static void setup(void) {
    ensure_fd();
    const char *msg = "streamlog loaded\n";
    write(g_fd, msg, strlen(msg));

    Method m = class_getInstanceMethod(objc_getClass("NSOutputStream"), @selector(write:maxLength:));
    if (m) {
        g_origWrite = method_getImplementation(m);
        method_setImplementation(m, (IMP)myWrite);
    }
    Method im = class_getInstanceMethod(objc_getClass("NSInputStream"), @selector(read:maxLength:));
    if (im) {
        g_origRead = method_getImplementation(im);
        method_setImplementation(im, (IMP)myRead);
    }
    const char *msg2 = "streamlog hooks installed\n";
    write(g_fd, msg2, strlen(msg2));
}
