#include <CoreFoundation/CoreFoundation.h>
// Probe: can a normal arm64 process seize the OTi USB interface?
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

static int propInt(io_service_t s, CFStringRef key, int *out) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(s, kIOServicePlane, key,
        kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!v) return 0;
    int ok = CFGetTypeID(v) == CFNumberGetTypeID();
    if (ok) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, out);
    CFRelease(v);
    return ok;
}

int main(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBInterface");
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return 1;
    io_service_t service = 0;
    while ((service = IOIteratorNext(iter))) {
        int vid = 0, pid = 0, num = -1;
        propInt(service, CFSTR("idVendor"), &vid);
        propInt(service, CFSTR("idProduct"), &pid);
        propInt(service, CFSTR("bInterfaceNumber"), &num);
        if (vid == 0x0EA0 && pid == 0x2213) {
            printf("found interface %d vid=%04x pid=%04x\n", num, vid, pid);
            IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
            kern_return_t kr = IOCreatePlugInInterfaceForService(service,
                kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
            printf("plugin kr=0x%x\n", kr);
            if (kr == KERN_SUCCESS && plugin) {
                IOUSBInterfaceInterface **intf = NULL;
                HRESULT hr = (*plugin)->QueryInterface(plugin,
                    CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
                printf("query hr=0x%x intf=%p\n", (unsigned)hr, (void *)intf);
                if (intf) {
                    IOReturn r = (*intf)->USBInterfaceOpen(intf);
                    printf("open r=0x%x\n", r);
                    if (r != kIOReturnSuccess) {
                        r = (*intf)->USBInterfaceOpenSeize(intf);
                        printf("openSeize r=0x%x\n", r);
                    }
                    if (r == kIOReturnSuccess) {
                        UInt8 n = 0; (*intf)->GetNumEndpoints(intf, &n);
                        printf("endpoints=%d\n", n);
                        for (UInt8 p = 1; p <= n; p++) {
                            UInt8 dir=0,num2=0,type=0,interval=0; UInt16 max=0;
                            (*intf)->GetPipeProperties(intf, p, &dir, &num2, &type, &max, &interval);
                            printf("pipe %d dir=%d num=%d type=%d max=%d\n", p, dir, num2, type, max);
                        }
                        (*intf)->USBInterfaceClose(intf);
                    }
                    (*intf)->Release(intf);
                }
                (*plugin)->Release(plugin);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return 0;
}
