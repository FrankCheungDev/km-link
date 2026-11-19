// Direct SCSITask user-client probe: bypass SCSITaskLib, build the 59-byte struct ourselves.
// Build: clang -target arm64-apple-macos13.0 -isysroot <SDK> -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

static void build(uint8_t *st, const uint8_t *cdb, void *buf, uint32_t len, int dir) {
    memset(st, 0, 59);
    *(uint32_t *)(st + 0) = 0;      // version 0 (daemon-style)
    *(uint32_t *)(st + 4) = 1;
    st[8] = 0;                       // LUN
    memcpy(st + 9, cdb, 16);
    st[25] = 0x10;
    *(uint64_t *)(st + 26) = len;
    st[34] = (uint8_t)dir;           // 1=OUT, 2=IN
    *(uint16_t *)(st + 35) = 2000;
    st[37] = 0; st[38] = 1;
    *(uint64_t *)(st + 42) = (uint64_t)(uintptr_t)buf;
    *(uint64_t *)(st + 50) = 0;
    st[58] = 0;
}

int main(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, CFSTR("SCSITaskDeviceCategory"), CFSTR("SCSITaskAuthoringDevice"));
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), props);
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
    if (kr) { printf("matching 0x%x\n", kr); return 1; }
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) { printf("no service\n"); return 1; }
    io_name_t nm = {0}; IORegistryEntryGetName(svc, nm);
    printf("service %s\n", nm);
    io_iterator_t iit = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("SCSITaskUserClientIniter"), &iit) == 0) {
        io_service_t initer = IOIteratorNext(iit);
        IOObjectRelease(iit);
        if (initer) {
            IOObjectRelease(svc);
            svc = initer;
            io_name_t inm = {0}; IORegistryEntryGetName(svc, inm);
            printf("using initer %s\n", inm);
        }
    }

    for (uint32_t type = 12; type <= 12; type++) {
        io_connect_t conn = 0;
        kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        printf("IOServiceOpen type=%u kr=0x%x conn=%u\n", type, kr, conn);
        if (kr != KERN_SUCCESS) continue;

        for (uint32_t sel = 0; sel <= 20; sel++) {
            uint64_t outv = 0; uint32_t outn = 1;
            kern_return_t sr = IOConnectCallScalarMethod(conn, sel, NULL, 0, &outv, &outn);
            if (sr != 0xe00002c2)
                printf("  scalar sel=%u kr=0x%x out=%llu\n", sel, sr, (unsigned long long)outv);
        }
        uint8_t *buf = calloc(1, 0x1000);
        uint8_t cdb[16] = {0x12,0,0,0,0x24,0,0,0,0,0,0,0,0,0,0,0};
        uint8_t in[59], out[64];
        for (int ver = 0; ver <= 1; ver++) {
            build(in, cdb, buf, 36, 2);
            in[0] = (uint8_t)ver;
            memset(out, 0, sizeof(out));
            size_t outCnt = sizeof(out);
            kern_return_t r = IOConnectCallStructMethod(conn, 6, in, sizeof(in), out, &outCnt);
            printf("  sel6 ver=%d kr=0x%x outCnt=%zu buf0=%02x%02x%02x%02x\n", ver, r, outCnt, buf[0],buf[1],buf[2],buf[3]);
        }
        size_t outCnt = sizeof(out);
        kern_return_t r = KERN_SUCCESS;
        printf("  sel6 kr=0x%x outCnt=%zu buf0=%02x%02x%02x%02x\n", r, outCnt, buf[0],buf[1],buf[2],buf[3]);
        if (r == KERN_SUCCESS) {
            printf("  INQUIRY ok: ");
            for (int i=0;i<36;i++) printf("%02x", buf[i]);
            printf("\n");
        }
        free(buf);
        IOServiceClose(conn);
    }
    return 0;
}
