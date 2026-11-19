// Minimal legacy-USB probe: seize device/interface and list bulk endpoints.
// Build: clang -target arm64-apple-macos13.0 -isysroot <SDK> \
//   -framework IOKit -framework CoreFoundation -o build/usb_probe tools/usb_probe.c
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>

static CFNumberRef num(int v) { return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v); }

int main(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBDevice");
    if (!match) { printf("no match dict\n"); return 1; }
    CFNumberRef vid = num(0x0EA0), pid = num(0x2213);
    CFDictionarySetValue(match, CFSTR("idVendor"), vid);
    CFDictionarySetValue(match, CFSTR("idProduct"), pid);
    CFRelease(vid); CFRelease(pid);

    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr) { printf("matching 0x%x\n", kr); return 1; }
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) { printf("no IOUSBDevice\n"); return 1; }
    printf("IOUSBDevice found\n");

    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plugin, &score);
    printf("device plugin kr=0x%x plugin=%p\n", kr, (void*)plugin);
    if (kr || !plugin) return 1;
    IOUSBDeviceInterface **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*)&dev);
    printf("device QI hr=0x%x dev=%p\n", (unsigned)hr, (void*)dev);
    if (hr || !dev) return 1;

    IOReturn r = (*dev)->USBDeviceOpenSeize(dev);
    printf("USBDeviceOpenSeize=0x%x\n", r);
    if (r) {
        r = (*dev)->USBDeviceOpen(dev);
        printf("USBDeviceOpen=0x%x\n", r);
        if (r) return 1;
    }

    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    io_iterator_t iit = 0;
    r = (*dev)->CreateInterfaceIterator(dev, &req, &iit);
    printf("CreateInterfaceIterator=0x%x\n", r);
    if (r) return 1;

    io_service_t isvc;
    while ((isvc = IOIteratorNext(iit))) {
        typedef kern_return_t (*TermFn)(io_service_t);
        TermFn termFn = (TermFn)dlsym(RTLD_DEFAULT, "IOServiceTerminate");
        if (termFn) {
            kern_return_t tr = termFn(isvc);
            printf("IOServiceTerminate=0x%x\n", tr);
        } else {
            printf("IOServiceTerminate symbol not found\n");
        }
        IOCFPlugInInterface **ipl = NULL; SInt32 sc = 0;
        kr = IOCreatePlugInInterfaceForService(isvc, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &ipl, &sc);
        IOUSBInterfaceInterface **intf = NULL;
        if (!kr && ipl)
            (*ipl)->QueryInterface(ipl, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID*)&intf);
        UInt8 cls=0, sub=0, proto=0, n=0;
        if (intf) {
            (*intf)->GetInterfaceClass(intf, &cls);
            (*intf)->GetInterfaceSubClass(intf, &sub);
            (*intf)->GetInterfaceProtocol(intf, &proto);
            IOReturn ir = (*intf)->USBInterfaceOpenSeize(intf);
            if (ir) ir = (*intf)->USBInterfaceOpen(intf);
            (*intf)->GetNumEndpoints(intf, &n);
            printf("interface cls=%u sub=%u proto=%u open=0x%x endpoints=%u\n", cls, sub, proto, ir, n);
            for (UInt8 p = 1; p <= n; p++) {
                UInt8 dir=0, num_=0, xfer=0, interval=0; UInt16 maxp=0;
                IOReturn pr = (*intf)->GetPipeProperties(intf, p, &dir, &num_, &xfer, &maxp, &interval);
                printf("  pipe %u: r=0x%x dir=%u num=%u type=%u maxp=%u\n", p, pr, dir, num_, xfer, maxp);
            }
        }
        if (ipl) (*ipl)->Release(ipl);
        IOObjectRelease(isvc);
    }
    IOObjectRelease(iit);
    return 0;
}
