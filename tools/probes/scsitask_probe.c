#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdio.h>
#include <string.h>

static int isAuthoring(io_service_t s) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("SCSITaskDeviceCategory"), kCFAllocatorDefault, 0);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        char b[128] = "";
        CFStringGetCString((CFStringRef)v, b, sizeof(b), kCFStringEncodingUTF8);
        ok = strcmp(b, "SCSITaskAuthoringDevice") == 0;
    }
    CFRelease(v);
    return ok;
}

static int probe(io_service_t svc, const char *cls) {
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc,
        kIOSCSITaskDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    printf("  [%s] plugin kr=0x%x score=%d\n", cls, kr, score);
    if (kr != KERN_SUCCESS || !plugin) return 0;

    SCSITaskDeviceInterface **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
    printf("  [%s] query hr=0x%x\n", cls, (unsigned)hr);
    if (!dev) { (*plugin)->Release(plugin); return 0; }

    kr = (*dev)->ObtainExclusiveAccess(dev);
    printf("  [%s] exclusive kr=0x%x\n", cls, kr);
    if (kr != KERN_SUCCESS) { (*dev)->Release(dev); (*plugin)->Release(plugin); return 0; }

    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) { printf("  [%s] no task\n", cls); (*dev)->ReleaseExclusiveAccess(dev); (*dev)->Release(dev); (*plugin)->Release(plugin); return 0; }

    UInt8 cdb[16] = {0xF0,0x00,0x00,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
    UInt8 buf[512]; memset(buf, 0, sizeof(buf));
    SCSITaskSGElement sg = { (uintptr_t)buf, sizeof(buf) };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0; UInt64 realized = 0;

    (*task)->SetCommandDescriptorBlock(task, cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sg, 1, sizeof(buf), kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);
    kr = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
    printf("  [%s] exec kr=0x%x status=0x%x realized=%llu\n", cls, kr, status, (unsigned long long)realized);
    if (realized) {
        printf("  [%s] data:", cls);
        for (int i = 0; i < 32 && i < (int)realized; i++) printf(" %02x", buf[i]);
        printf("\n");
    }
    (*task)->Release(task);
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
    (*plugin)->Release(plugin);
    return kr == KERN_SUCCESS;
}

int main(void) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOService"), &iter) != KERN_SUCCESS) return 1;
    io_service_t s; int n = 0, okCount = 0;
    CFMutableArrayRef seen = CFArrayCreateMutable(NULL, 0, NULL);
    while ((s = IOIteratorNext(iter))) {
        if (isAuthoring(s)) {
            char cls[128] = "?";
            IOObjectGetClass(s, cls);
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt64Type, &(int64_t){ (int64_t)s });
            int dup = 0;
            for (CFIndex i = 0; i < CFArrayGetCount(seen); i++) {
                if (CFArrayGetValueAtIndex(seen, i) == (const void *)num) dup = 1;
            }
            printf("authoring[%d] class=%s entry=0x%llx\n", n, cls, (unsigned long long)s);
            n++;
            if (probe(s, cls)) okCount++;
            CFRelease(num);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(iter);
    CFRelease(seen);
    printf("total=%d success=%d\n", n, okCount);
    return okCount > 0 ? 0 : 7;
}
