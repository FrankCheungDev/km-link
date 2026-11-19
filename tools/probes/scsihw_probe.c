#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int main(void) {
    io_service_t svc = 0; io_iterator_t it = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOCompactDiscServices"), &it);
    svc = IOIteratorNext(it);
    if (!svc) { printf("no IOCompactDiscServices\n"); return 1; }
    char cls[128]="?"; IOObjectGetClass(svc, cls);
    printf("service class=%s\n", cls);

    for (uint32_t type = 0; type <= 16; type++) {
        io_connect_t conn = 0;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        if (kr != KERN_SUCCESS) continue;
        printf("type=%u OPEN conn=0x%x\n", type, conn);
        // brute force selectors with the observed 59-byte task struct
        for (uint32_t sel = 0; sel <= 12; sel++) {
            uint8_t in[64]; memset(in, 0, sizeof(in));
            uint8_t cdb[16] = {0xF0,0x00,0x00,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
            memcpy(in + 9, cdb, 16);
            uint8_t buf[512]; memset(buf, 0, sizeof(buf));
            *(uint32_t *)(in + 26) = 512;
            in[34] = 2;
            *(uint64_t *)(in + 43) = (uintptr_t)buf;
            uint8_t out[128]; size_t oc = sizeof(out);
            kern_return_t r = IOConnectCallStructMethod(conn, sel, in, 59, out, &oc);
            if (r == KERN_SUCCESS || r == 0xe00002bc || oc != sizeof(out)) {
                printf("  sel=%u kr=0x%x outCnt=%zu", sel, r, oc);
                if (r == KERN_SUCCESS) { printf(" data:"); for (int i=0;i<24;i++) printf(" %02x", buf[i]); }
                printf("\n");
            }
        }
        IOServiceClose(conn);
    }
    IOObjectRelease(svc); IOObjectRelease(it);
    return 0;
}
