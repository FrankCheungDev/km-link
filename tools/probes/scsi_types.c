// Enumerate SCSITask user-client types on the matched service.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

int main(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, CFSTR("SCSITaskDeviceCategory"), CFSTR("SCSITaskAuthoringDevice"));
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), props);
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)) { printf("no match\n"); return 1; }
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) { printf("no service\n"); return 1; }

    for (uint32_t type = 0; type <= 24; type++) {
        io_connect_t conn = 0;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
        if (kr != KERN_SUCCESS) continue;
        printf("type=%u conn=%u\n", type, conn);
        for (uint32_t sel = 1; sel <= 3; sel += 2) {
            uint64_t out = 0; uint32_t outn = 1;
            kern_return_t sr = IOConnectCallScalarMethod(conn, sel, NULL, 0, &out, &outn);
            printf("  sel=%u kr=0x%x out=%llu\n", sel, sr, (unsigned long long)out);
        }
        IOServiceClose(conn);
    }
    return 0;
}
