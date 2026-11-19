// Probe the private IOUSBHost.framework ObjC API for exclusive device/interface access.
// Build: clang -target arm64-apple-macos13.0 -isysroot <SDK> -framework Foundation -framework IOKit
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>

@interface IOUSBHostDevice : NSObject
- (id)initWithIOService:(io_service_t)service options:(NSUInteger)options
                  queue:(dispatch_queue_t)queue error:(NSError **)error
        interestHandler:(id)handler;
- (BOOL)openWithOptions:(NSUInteger)options error:(NSError **)error;
- (BOOL)closeWithOptions:(NSUInteger)options error:(NSError **)error;
- (BOOL)configureWithValue:(uint8_t)value matchInterfaces:(BOOL)match error:(NSError **)error;
- (BOOL)resetWithError:(NSError **)error;
@end

@interface IOUSBHostInterface : NSObject
- (id)initWithIOService:(io_service_t)service options:(NSUInteger)options
                  queue:(dispatch_queue_t)queue error:(NSError **)error
        interestHandler:(id)handler;
- (BOOL)openWithOptions:(NSUInteger)options error:(NSError **)error;
- (id)copyPipeWithAddress:(NSUInteger)address error:(NSError **)error;
@end

static int propInt(io_service_t s, const char *key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8), kCFAllocatorDefault, 0);
    int r = -1;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &r);
        CFRelease(v);
    }
    return r;
}

int main(void) {
    dlopen("/System/Library/Frameworks/IOUSBHost.framework/IOUSBHost", RTLD_LAZY);
    Class devCls = NSClassFromString(@"IOUSBHostDevice");
    Class intfCls = NSClassFromString(@"IOUSBHostInterface");
    printf("classes dev=%p intf=%p\n", (void*)devCls, (void*)intfCls);
    if (!devCls || !intfCls) return 1;

    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    int vid = 0x0EA0, pid = 0x2213;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), nv);
    CFDictionarySetValue(match, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) || !it) {
        printf("no IOUSBHostDevice\n"); return 1;
    }
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) { printf("no device service\n"); return 1; }

    NSError *err = nil;
    IOUSBHostDevice *dev = [[devCls alloc] initWithIOService:svc options:0
                                                      queue:dispatch_get_main_queue()
                                                      error:&err interestHandler:nil];
    printf("device init=%p err=%s\n", (void*)dev, err ? err.localizedDescription.UTF8String : "nil");
    if (!dev) return 1;

    BOOL ok = [dev openWithOptions:0 error:&err];
    printf("device open(shared) ok=%d err=%s\n", ok, err ? err.localizedDescription.UTF8String : "nil");
    if (!ok) return 1;

    err = nil;
    BOOL cfg = [dev configureWithValue:1 matchInterfaces:YES error:&err];
    printf("configure ok=%d err=%s\n", cfg, err ? err.localizedDescription.UTF8String : "nil");
    err = nil;
    BOOL rst = [dev resetWithError:&err];
    printf("reset ok=%d err=%s\n", rst, err ? err.localizedDescription.UTF8String : "nil");
    sleep(1);

    CFMutableDictionaryRef imatch = IOServiceMatching("IOUSBHostInterface");
    io_iterator_t iit = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, imatch, &iit) || !iit) {
        printf("no interfaces\n"); return 1;
    }
    io_service_t isvc;
    int found = 0;
    while ((isvc = IOIteratorNext(iit))) {
        int cls = propInt(isvc, "bInterfaceClass");
        int sub = propInt(isvc, "bInterfaceSubClass");
        int proto = propInt(isvc, "bInterfaceProtocol");
        if (cls == 8 && sub == 6) {
            io_name_t icls = {0}; IOObjectGetClass(isvc, icls);
            io_service_t parent = 0; io_name_t pcls = {0};
            IORegistryEntryGetParentEntry(isvc, kIOServicePlane, &parent);
            if (parent) { IOObjectGetClass(parent, pcls); IOObjectRelease(parent); }
            uint64_t devId = 0, ifId = 0;
            IORegistryEntryGetRegistryEntryID(svc, &devId);
            IORegistryEntryGetRegistryEntryID(isvc, &ifId);
            printf("interface %d/%d/%d service=%u class=%s parent=%s ifId=%llu devId=%llu\n",
                   cls, sub, proto, isvc, icls, pcls, ifId, devId);
            IOUSBHostInterface *intf = nil;
            for (NSUInteger iopt = 0; iopt <= 3 && !intf; iopt++) {
                err = nil;
                intf = [[intfCls alloc] initWithIOService:isvc options:iopt
                                                    queue:dispatch_get_main_queue()
                                                    error:&err interestHandler:nil];
                printf("  init opt=%lu -> %p err=%s code=%ld\n", (unsigned long)iopt, (void*)intf,
                       err ? err.localizedDescription.UTF8String : "nil",
                       err ? (long)err.code : 0);
            }
            if (intf) {
                err = nil;
                BOOL iok = [intf openWithOptions:1 error:&err];
                printf("  open(exclusive) ok=%d err=%s\n", iok, err ? err.localizedDescription.UTF8String : "nil");
                if (!iok) {
                    err = nil;
                    iok = [intf openWithOptions:0 error:&err];
                    printf("  open(shared) ok=%d err=%s\n", iok, err ? err.localizedDescription.UTF8String : "nil");
                }
                if (iok) {
                    for (int a = 1; a <= 2; a++) {
                        err = nil;
                        id pipe = [intf copyPipeWithAddress:(a == 1 ? 0x81 : 0x02) error:&err];
                        printf("  pipe 0x%02x=%p err=%s\n", a == 1 ? 0x81 : 0x02,
                               (void*)pipe, err ? err.localizedDescription.UTF8String : "nil");
                    }
                }
            }
            found = 1;
            IOObjectRelease(isvc);
            break;
        }
        IOObjectRelease(isvc);
    }
    IOObjectRelease(iit);
    printf("found=%d\n", found);
    return found ? 0 : 1;
}
