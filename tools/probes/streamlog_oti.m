// Interpose OTiTransfer's exported C API to capture real 64 KB frames.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <mach/mach.h>

extern int OTi_SendData(const void *buffer);
extern int OTi_ReadData(void *buffer);
static int (*g_send)(const void *);
static int (*g_read)(void *);
static int g_fd = -1;

static void ensure_fd(void) { if (g_fd < 0) g_fd = open("/tmp/kmlink-oti.log", O_WRONLY|O_CREAT|O_APPEND, 0644); }

static void logbuf(const char *tag, const uint8_t *b, long len) {
    if (!b || len <= 0) return;
    ensure_fd();
    char line[4096];
    int n = snprintf(line, sizeof(line), "%s len=%ld ", tag, len);
    for (int i = 0; i < 32 && i < len; i++) n += snprintf(line+n, sizeof(line)-n, "%02x", b[i]);
    if (len >= 20) {
        const uint32_t *h = (const uint32_t *)b;
        n += snprintf(line+n, sizeof(line)-n, " hdr=%u,%u,%u,%u,%u", h[0],h[1],h[2],h[3],h[4]);
    }
    n += snprintf(line+n, sizeof(line)-n, "\n");
    write(g_fd, line, n);
    for (long i = 0; i + 8 < len && i < 0x10000; i++) {
        if (!memcmp(b+i, "<OTIMSG>", 8) || !memcmp(b+i, "OTIMSG", 6)) {
            int m = snprintf(line, sizeof(line), "%s XML@0x%lx: ", tag, i);
            for (int j = 0; j < 1200 && i+j < len; j++) {
                unsigned char c = b[i+j];
                m += snprintf(line+m, sizeof(line)-m, "%c", (c>=32&&c<127)?c:'.');
            }
            m += snprintf(line+m, sizeof(line)-m, "\n");
            write(g_fd, line, m);
            break;
        }
    }
}

static void dumpHead(const uint8_t *b) {
    ensure_fd();
    uint8_t tmp[0x140];
    vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)b, sizeof(tmp), (vm_address_t)tmp, &got) != KERN_SUCCESS || got < 32) return;
    b = tmp;
    char line[2048];
    for (int off = 0; off + 32 <= (int)got; off += 32) {
        if (off == 0x100) break;
        int n = snprintf(line, sizeof(line), "HEAD %03x: ", off);
        for (int i = 0; i < 32; i++) n += snprintf(line+n, sizeof(line)-n, "%02x", b[off+i]);
        n += snprintf(line+n, sizeof(line)-n, "  ");
        for (int i = 0; i < 32; i++) { unsigned char c=b[off+i]; n += snprintf(line+n, sizeof(line)-n, "%c", (c>=32&&c<127)?c:'.'); }
        n += snprintf(line+n, sizeof(line)-n, "\n");
        write(g_fd, line, n);
    }
}
static void dumpTail(const uint8_t *b) {
    ensure_fd();
    uint8_t tmp[64];
    vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)(b + 0xFFE0), sizeof(tmp), (vm_address_t)tmp, &got) != KERN_SUCCESS || got < 32) return;
    char line[512];
    int n = snprintf(line, sizeof(line), "TAIL ffe0: ");
    for (int i = 0; i < 32; i++) n += snprintf(line+n, sizeof(line)-n, "%02x", tmp[i]);
    n += snprintf(line+n, sizeof(line)-n, "\n");
    write(g_fd, line, n);
}
static void dumpPayload(const uint8_t *b) {
    uint8_t hdr[20];
    vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)b, 20, (vm_address_t)hdr, &got) != KERN_SUCCESS || got < 20) return;
    uint32_t plen = *(uint32_t *)(hdr + 16);
    if (plen == 0 || plen > 0x10000) return;
    size_t n = plen < 0x800 ? plen : 0x800;
    uint8_t *tmp = malloc(n + 0x14);
    if (!tmp) return;
    vm_read_overwrite(mach_task_self(), (vm_address_t)b, n + 0x14, (vm_address_t)tmp, &got);
    ensure_fd();
    char line[2048];
    for (size_t off = 0x14; off < 0x14 + n; off += 32) {
        size_t lim = 0x14 + n - off; if (lim > 32) lim = 32;
        int m = snprintf(line, sizeof(line), "PAY %04zx: ", off - 0x14);
        for (size_t i = 0; i < lim; i++) m += snprintf(line+m, sizeof(line)-m, "%02x", tmp[off+i]);
        m += snprintf(line+m, sizeof(line)-m, "  ");
        for (size_t i = 0; i < lim; i++) { unsigned char c=tmp[off+i]; m += snprintf(line+m, sizeof(line)-m, "%c", (c>=32&&c<127)?c:'.'); }
        m += snprintf(line+m, sizeof(line)-m, "\n");
        write(g_fd, line, m);
    }
    free(tmp);
}
static int mySend(const void *buf) {
    dumpHead((const uint8_t *)buf);
    dumpTail((const uint8_t *)buf);
    dumpPayload((const uint8_t *)buf);
    logbuf("SEND", (const uint8_t *)buf, 0x10000);
    return g_send ? g_send(buf) : -1;
}
static int myRead(void *buf) {
    int r = g_read ? g_read(buf) : -1;
    if (r > 0) logbuf("RECV", (const uint8_t *)buf, r);
    return r;
}

struct interpose_s { const void *new_func; const void *orig_func; };
__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_s interposes[] = {
    { (const void *)mySend, (const void *)OTi_SendData },
    { (const void *)myRead, (const void *)OTi_ReadData },
};

__attribute__((constructor)) static void setup(void) {
    ensure_fd();
    g_send = (int (*)(const void *))interposes[0].orig_func;
    g_read = (int (*)(void *))interposes[1].orig_func;
    if ((void *)g_send == (void *)mySend) g_send = NULL;
    if ((void *)g_read == (void *)myRead) g_read = NULL;
    char msg[160];
    int n = snprintf(msg, sizeof(msg), "oti interpose loaded send=%p read=%p self=%p\n", (void*)g_send, (void*)g_read, (void*)mySend);
    write(g_fd, msg, n);
}
