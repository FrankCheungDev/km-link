// hidrestore.c — read/restore the OTi bridge virtual-mouse HID acceleration.
// Build:
//   SDK=$(xcrun --show-sdk-path)
//   clang -target arm64-apple-macos13.0 -isysroot "$SDK" -framework IOKit -framework CoreFoundation -o /tmp/hidrestore tools/hidrestore.c

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>
#include <stdio.h>
#include <stdlib.h>

static int match(IOHIDServiceClientRef svc) {
    long long vid = 0, pid = 0, upg = 0, usg = 0;
    CFTypeRef v;
    v = IOHIDServiceClientCopyProperty(svc, CFSTR("VendorID")); if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &vid); CFRelease(v);} 
    v = IOHIDServiceClientCopyProperty(svc, CFSTR("ProductID")); if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &pid); CFRelease(v);} 
    v = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage")); if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &upg); CFRelease(v);} 
    v = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage")); if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &usg); CFRelease(v);} 
    return vid == 0x0EA0 && pid == 0x2213 && upg == 1 && usg == 2;
}

static void apply(IOHIDServiceClientRef svc, int32_t ptr, int32_t mse) {
    CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &ptr);
    CFNumberRef m = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &mse);
    IOHIDServiceClientSetProperty(svc, CFSTR(kIOHIDPointerAccelerationKey), p);
    IOHIDServiceClientSetProperty(svc, CFSTR(kIOHIDMouseAccelerationTypeKey), m);
    CFRelease(p); CFRelease(m);
}

static void report(IOHIDServiceClientRef svc, const char *tag) {
    CFTypeRef v;
    long long p = -1, m = -1;
    v = IOHIDServiceClientCopyProperty(svc, CFSTR(kIOHIDPointerAccelerationKey));
    if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &p); CFRelease(v);} 
    v = IOHIDServiceClientCopyProperty(svc, CFSTR(kIOHIDMouseAccelerationTypeKey));
    if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &m); CFRelease(v);} 
    printf("%s HIDPointerAcceleration=%lld HIDMouseAcceleration=%lld\n", tag, p, m);
}

int main(int argc, char **argv) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    CFIndex n = CFArrayGetCount(services);
    int done = 0;
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!match(svc)) continue;
        report(svc, "before:");
        if (argc >= 3 && argv[1][0] == 's') {
            int32_t ptr = atoi(argv[2]);
            int32_t mse = atoi(argv[3]);
            apply(svc, ptr, mse);
            report(svc, "after: ");
        }
        done++;
    }
    printf("matched=%d\n", done);
    CFRelease(services); CFRelease(client);
    return done ? 0 : 1;
}

// Usage:
//   /tmp/hidrestore read              # show HIDPointerAcceleration / HIDMouseAcceleration
//   /tmp/hidrestore set 45056 32768   # write the macOS defaults for this device
//
// KMLink now restores these automatically at start-up, on disconnect and on
// quit (see oti_hid_restore_mouse_defaults in Sources/SCSITaskShim.c). Keep this
// tool around to heal a machine that still has a bad value from an older build.
