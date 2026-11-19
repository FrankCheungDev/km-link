// hidprobe.c — dump every IOHIDEventSystemClient service and the OTi mouse properties.
// Build:
//   SDK=$(xcrun --show-sdk-path)
//   clang -target arm64-apple-macos13.0 -isysroot "$SDK" -framework IOKit -framework CoreFoundation -o /tmp/hidprobe tools/hidprobe.c

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>
#include <stdio.h>

static void dumpProp(IOHIDServiceClientRef svc, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IOHIDServiceClientCopyProperty(svc, k);
    if (v) {
        char buf[256] = {0};
        CFStringRef s = NULL;
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            long long n = 0; CFNumberGetValue(v, kCFNumberSInt64Type, &n);
            printf("    %s = %lld\n", key, n);
        } else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            printf("    %s = %s\n", key, CFBooleanGetValue(v) ? "true" : "false");
        } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
            s = v;
            if (CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) printf("    %s = %s\n", key, buf);
        } else {
            s = CFCopyDescription(v);
            if (s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) printf("    %s = %s\n", key, buf);
            if (s) CFRelease(s);
        }
        CFRelease(v);
    }
    CFRelease(k);
}

int main(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) { printf("client create failed\n"); return 1; }
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { printf("no services\n"); return 1; }
    CFIndex n = CFArrayGetCount(services);
    printf("services=%ld\n", (long)n);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        long long vid = -1, pid = -1, upg = -1, usg = -1;
        CFStringRef k;
        CFTypeRef v;
        k = CFSTR("VendorID"); v = IOHIDServiceClientCopyProperty(svc, k);
        if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt64Type, &vid); CFRelease(v);} 
        k = CFSTR("ProductID"); v = IOHIDServiceClientCopyProperty(svc, k);
        if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt64Type, &pid); CFRelease(v);} 
        k = CFSTR("PrimaryUsagePage"); v = IOHIDServiceClientCopyProperty(svc, k);
        if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt64Type, &upg); CFRelease(v);} 
        k = CFSTR("PrimaryUsage"); v = IOHIDServiceClientCopyProperty(svc, k);
        if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt64Type, &usg); CFRelease(v);} 
        printf("[%ld] VID=%lld PID=%lld usagePage=%lld usage=%lld\n", (long)i, vid, pid, upg, usg);
        if (vid == 0x0EA0 && pid == 0x2213) {
            dumpProp(svc, "Product");
            dumpProp(svc, "Transport");
            dumpProp(svc, "HIDPointerAcceleration");
            dumpProp(svc, "HIDMouseAcceleration");
            dumpProp(svc, "HIDUseLinearScalingMouseAcceleration");
            dumpProp(svc, "HIDMouseScrollAcceleration");
            dumpProp(svc, "HIDScrollAcceleration");
            dumpProp(svc, "HIDPointerButtonMode");
            dumpProp(svc, "ReportInterval");
            dumpProp(svc, "HIDDefaultBehavior");
        }
    }
    CFRelease(services);
    CFRelease(client);
    return 0;
}
