// Interpose DiskArbitration mount/unmount to observe OTiTransporter's media handling.
#include <DiskArbitration/DiskArbitration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdarg.h>

static int g_fd = -1;
static int g_count = 0;

static void ensure_fd(void) { if (g_fd < 0) g_fd = open("/tmp/kmlink-disk.log", O_WRONLY|O_CREAT|O_APPEND, 0644); }

static void logline(const char *fmt, ...) {
    ensure_fd();
    char line[1024];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n > 0) write(g_fd, line, n);
}

static const char *bsdName(DADiskRef disk) {
    const char *n = disk ? DADiskGetBSDName(disk) : NULL;
    return n ? n : "(null)";
}

static int (*g_unmount)(DADiskRef, DADiskUnmountOptions, DADiskUnmountCallback, void *);
static int (*g_mount)(DADiskRef, CFURLRef, DADiskMountOptions, DADiskMountCallback, void *);

static int myUnmount(DADiskRef disk, DADiskUnmountOptions opts, DADiskUnmountCallback cb, void *ctx) {
    if (g_count++ < 100) logline("UNMOUNT bsd=%s opts=0x%x\n", bsdName(disk), (unsigned)opts);
    int r = g_unmount ? g_unmount(disk, opts, cb, ctx) : -1;
    if (g_count < 100) logline("UNMOUNT ret=%d bsd=%s\n", r, bsdName(disk));
    return r;
}

static int myMount(DADiskRef disk, CFURLRef url, DADiskMountOptions opts, DADiskMountCallback cb, void *ctx) {
    if (g_count++ < 100) logline("MOUNT bsd=%s opts=0x%x url=%p\n", bsdName(disk), (unsigned)opts, (void*)url);
    int r = g_mount ? g_mount(disk, url, opts, cb, ctx) : -1;
    if (g_count < 100) logline("MOUNT ret=%d bsd=%s\n", r, bsdName(disk));
    return r;
}

struct interpose_s { const void *new_func; const void *orig_func; };
__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_s interposes[] = {
    { (const void *)myUnmount, (const void *)DADiskUnmount },
    { (const void *)myMount,   (const void *)DADiskMount },
};

__attribute__((constructor)) static void setup(void) {
    ensure_fd();
    g_unmount = (int (*)(DADiskRef, DADiskUnmountOptions, DADiskUnmountCallback, void *))interposes[0].orig_func;
    g_mount   = (int (*)(DADiskRef, CFURLRef, DADiskMountOptions, DADiskMountCallback, void *))interposes[1].orig_func;
    if ((void *)g_unmount == (void *)myUnmount) g_unmount = NULL;
    if ((void *)g_mount == (void *)myMount) g_mount = NULL;
    logline("disklog loaded unmount=%p mount=%p\n", (void*)g_unmount, (void*)g_mount);
}
