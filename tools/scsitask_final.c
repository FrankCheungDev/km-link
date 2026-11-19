// Native (arm64, no entitlement, no Rosetta) SCSI task access:
// dlopen the Apple SCSITaskLib plugin, use its factory, drive the documented interface.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define PLUGIN "/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext/Contents/PlugIns/SCSITaskUserClient.kext/Contents/PlugIns/SCSITaskLib.plugin/Contents/MacOS/SCSITaskLib"

typedef void *(*FactoryFn)(void *allocator, CFUUIDRef typeUUID);

int main(void) {
    void *h = dlopen(PLUGIN, RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    FactoryFn factory = (FactoryFn)dlsym(h, "SCSITaskLibFactory");
    printf("factory=%p\n", (void *)factory);
    if (!factory) return 2;

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOCompactDiscServices"));
    if (!svc) { printf("no service\n"); return 3; }

    IOCFPlugInInterface **plugin = (IOCFPlugInInterface **)factory(NULL, kIOSCSITaskDeviceUserClientTypeID);
    printf("plugin=%p\n", (void *)plugin);
    if (!plugin) return 4;

    SInt32 score = 0;
    IOReturn pr = (*plugin)->Probe(plugin, NULL, svc, &score);
    printf("probe kr=0x%x score=%d\n", pr, score);
    IOReturn st = (*plugin)->Start(plugin, NULL, svc);
    printf("start kr=0x%x\n", st);
    if (st != kIOReturnSuccess) { printf("start failed\n"); return 9; }

    SCSITaskDeviceInterface **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
    printf("query hr=0x%x dev=%p\n", (unsigned)hr, (void *)dev);
    if (!dev) return 5;

    // plugin's InitWithConnection opens by service + type 12
    kern_return_t kr = (*dev)->ObtainExclusiveAccess(dev);
    printf("exclusive kr=0x%x\n", kr);
    if (kr != KERN_SUCCESS) return 6;

    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    printf("task=%p\n", (void *)task);
    if (!task) return 7;

    UInt8 cdb[16] = {0xF0,0x00,0x00,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
    UInt8 buf[512]; memset(buf, 0, sizeof(buf));
    SCSITaskSGElement sg = { (uintptr_t)buf, sizeof(buf) };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0; UInt64 realized = 0;

    (*task)->SetCommandDescriptorBlock(task, cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sg, 1, sizeof(buf), kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);
    kr = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
    printf("EXEC kr=0x%x status=0x%x realized=%llu\n", kr, status, (unsigned long long)realized);
    if (realized) {
        printf("data:");
        for (int i = 0; i < 48 && i < (int)realized; i++) printf(" %02x", buf[i]);
        printf("\n");
        char ascii[49]; int n = realized < 48 ? (int)realized : 48;
        for (int i = 0; i < n; i++) ascii[i] = (buf[i] >= 32 && buf[i] < 127) ? buf[i] : '.';
        ascii[n] = 0; printf("ascii: %s\n", ascii);
    }
    (*task)->Release(task);
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
    (*plugin)->Release(plugin);
    IOObjectRelease(svc);
    dlclose(h);
    return kr == KERN_SUCCESS ? 0 : 8;
}
