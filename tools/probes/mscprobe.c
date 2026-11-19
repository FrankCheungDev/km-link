#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

static void tryClass(const char *cls) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
    if (!svc) { printf("%s: no service\n", cls); return; }
    for (uint32_t type = 0; type < 6; type++) {
        io_connect_t conn = 0;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        printf("%s type=%u open kr=0x%x conn=0x%x\n", cls, type, kr, conn);
        if (kr != KERN_SUCCESS) continue;
        uint8_t cdb[16] = {0xF0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
        uint8_t in[59]; memset(in, 0, sizeof(in));
        memcpy(in + 9, cdb, 16);
        *(uint32_t *)(in + 26) = 512;
        in[34] = 2;
        uint8_t buf[512]; memset(buf, 0, sizeof(buf));
        *(uint64_t *)(in + 43) = (uintptr_t)buf;
        uint8_t out[59]; size_t outCnt = sizeof(out);
        kr = IOConnectCallStructMethod(conn, 6, in, sizeof(in), out, &outCnt);
        printf("  sel6 kr=0x%x out=%zu buf0=%02x %02x %02x %02x\n", kr, outCnt, buf[0], buf[1], buf[2], buf[3]);
        IOServiceClose(conn);
        if (kr == KERN_SUCCESS) return;
    }
    IOObjectRelease(svc);
}

int main(void) {
    const char *classes[] = {"IOUSBMassStorageDriver", "IOUSBMassStorageDriverNub", "IOUSBMassStorageInterfaceNub", "IOSCSIPeripheralDeviceType00"};
    for (int i = 0; i < 4; i++) tryClass(classes[i]);
    return 0;
}
