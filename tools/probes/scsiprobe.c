// Minimal SCSITaskUserClient probe for the OTi vendor device.
// Build: clang -isysroot <SDK> -framework IOKit -framework CoreFoundation -o build/scsiprobe tools/scsiprobe.c
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *bsd = argc > 1 ? argv[1] : "disk4";
    CFMutableDictionaryRef match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) { printf("no service for %s\n", bsd); return 1; }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = KERN_FAILURE;
    for (int depth = 0; depth < 8 && service; depth++) {
        io_name_t cls; IOObjectGetClass(service, cls);
        kr = IOCreatePlugInInterfaceForService(service,
            kIOSCSITaskDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        printf("depth=%d class=%s plugin kr=0x%x score=%d\n", depth, cls, kr, score);
        if (kr == KERN_SUCCESS) break;
        if (plugin) { (*plugin)->Release(plugin); plugin = NULL; }
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(service);
        service = parent;
    }
    if (kr != KERN_SUCCESS) return 2;

    SCSITaskDeviceInterface **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
    printf("query hr=0x%x dev=%p\n", (unsigned)hr, (void *)dev);
    if (!dev) return 3;

    kr = (*dev)->ObtainExclusiveAccess(dev);
    printf("exclusive kr=0x%x\n", kr);
    if (kr != KERN_SUCCESS) return 4;

    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) { printf("no task\n"); return 5; }

    UInt8 cdb[16] = {0xF0,0x00,0x00,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
    UInt8 buf[512]; memset(buf, 0, sizeof(buf));
    SCSITaskSGElement sg = { (uintptr_t)buf, sizeof(buf) };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0; UInt64 realized = 0;

    (*task)->SetCommandDescriptorBlock(task, cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sg, 1, sizeof(buf),
                                     kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);
    kr = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
    printf("exec kr=0x%x status=0x%x realized=%llu\n", kr, status, (unsigned long long)realized);
    for (int i = 0; i < 32 && i < (int)realized; i++) printf("%02x ", buf[i]);
    printf("\n");

    (*task)->Release(task);
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
    (*plugin)->Release(plugin);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : 6;
}
