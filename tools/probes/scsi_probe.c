// Minimal SCSITaskUserClient probe for the OTi bridge.
// Build:
//   clang -target arm64-apple-macos13.0 -isysroot <SDK> \
//     -framework IOKit -framework CoreFoundation -o build/scsi_probe tools/scsi_probe.c
#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/scsi/SCSITask.h>
#include <IOKit/scsi/SCSICommandOperationCodes.h>
#include <CoreFoundation/CoreFoundation.h>

static void printBytes(const char *label, const uint8_t *bytes, size_t count) {
    printf("%s", label);
    for (size_t i = 0; i < count; i++) printf("%02x", bytes[i]);
    printf("\n");
}


static void runVendor(SCSITaskDeviceInterface **device, const uint8_t *cdb, uint32_t dataLen, const char *label) {
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) { printf("%s: no task\n", label); return; }
    uint8_t *buffer = calloc(1, dataLen);
    SCSITaskSGElement sge = { (uint64_t)(uintptr_t)buffer, dataLen };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0; UInt64 transferred = 0;
    (*task)->SetTaskAttribute(task, (SCSITaskAttribute)0);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sge, 1, dataLen, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 2000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));
    IOReturn r = (*task)->ExecuteTaskSync(task, NULL, &status, &transferred);
    SCSIServiceResponse sr = 0; (*task)->GetSCSIServiceResponse(task, &sr);
    printf("%s: result=0x%x service=%u status=%u transferred=%llu data=", label, r, sr, status, (unsigned long long)transferred);
    for (UInt64 i = 0; i < transferred && i < dataLen; i++) printf("%02x", buffer[i]);
    printf("\n");
    free(buffer);
    (*task)->Release(task);
}


static IOReturn sendFrame(SCSITaskDeviceInterface **device, const uint8_t *cdb,
                          const uint8_t *data, uint32_t len,
                          SCSITaskStatus *statusOut, UInt64 *transferredOut) {
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) return kIOReturnError;
    SCSITaskSGElement sge = { (uint64_t)(uintptr_t)data, len };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    (*task)->SetTaskAttribute(task, (SCSITaskAttribute)0);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sge, 1, len, kSCSIDataTransfer_FromInitiatorToTarget);
    (*task)->SetTimeoutDuration(task, 5000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));
    IOReturn r = (*task)->ExecuteTaskSync(task, NULL, statusOut, transferredOut);
    printf("frame result=0x%x status=%u transferred=%llu sense=", r, statusOut?*statusOut:0,
           (unsigned long long)(transferredOut?*transferredOut:0));
    for (size_t i=0;i<sizeof(sense);i++) printf("%02x", ((uint8_t*)&sense)[i]);
    printf("\n");
    (*task)->Release(task);
    return r;
}


static IOReturn sendNoData(SCSITaskDeviceInterface **device, const uint8_t *cdb,
                           SCSITaskStatus *statusOut) {
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) return kIOReturnError;
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    (*task)->SetTaskAttribute(task, (SCSITaskAttribute)0);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    (*task)->SetTimeoutDuration(task, 5000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));
    IOReturn r = (*task)->ExecuteTaskSync(task, NULL, statusOut, NULL);
    printf("nodata result=0x%x status=%u sense=", r, statusOut?*statusOut:0);
    for (size_t i=0;i<sizeof(sense);i++) printf("%02x", ((uint8_t*)&sense)[i]);
    printf("\n");
    (*task)->Release(task);
    return r;
}


static IOReturn readCmd(SCSITaskDeviceInterface **device, const uint8_t *cdb,
                        void *data, uint32_t len, SCSITaskStatus *statusOut, UInt64 *trOut) {
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) return kIOReturnError;
    SCSITaskSGElement sge = { (uint64_t)(uintptr_t)data, len };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    (*task)->SetTaskAttribute(task, (SCSITaskAttribute)0);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sge, 1, len, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 2000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));
    IOReturn r = (*task)->ExecuteTaskSync(task, NULL, statusOut, trOut);
    (*task)->Release(task);
    return r;
}



typedef struct { volatile int done; SCSIServiceResponse sr; SCSITaskStatus st; UInt64 tr; } KAsyncCtx;
static void kAsyncCb(SCSIServiceResponse sr, SCSITaskStatus st, UInt64 tr, void *ref) {
    KAsyncCtx *c = (KAsyncCtx *)ref;
    c->sr = sr; c->st = st; c->tr = tr; c->done = 1;
}
static IOReturn sendFrameAsync(SCSITaskDeviceInterface **device, const uint8_t *cdb,
                               void *data, uint32_t len, SCSITaskStatus *statusOut, UInt64 *trOut) {
    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) return kIOReturnError;
    SCSITaskSGElement sge = { (uint64_t)(uintptr_t)data, len };
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof(sense));
    (*task)->SetTaskAttribute(task, (SCSITaskAttribute)0);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, 16);
    (*task)->SetScatterGatherEntries(task, &sge, 1, len, kSCSIDataTransfer_FromInitiatorToTarget);
    (*task)->SetTimeoutDuration(task, 2000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));
    KAsyncCtx ctx; memset(&ctx, 0, sizeof(ctx));
    (*task)->SetTaskCompletionCallback(task, kAsyncCb, &ctx);
    IOReturn r = (*task)->ExecuteTaskAsync(task);
    int spins = 0;
    while (!ctx.done && spins++ < 100) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    if (statusOut) *statusOut = ctx.st;
    if (trOut) *trOut = ctx.tr;
    (*task)->Release(task);
    return r;
}

static int nativeSend(SCSITaskDeviceInterface **device, int skipRead) {
    uint8_t cdb[16]; SCSITaskStatus st = 0; UInt64 tr = 0;
    uint8_t *big = calloc(1, 0x10000);
    if (!skipRead) {
        int mr = system("diskutil mount /dev/disk5s0 >/tmp/native-mount.log 2>&1");
        printf("NATIVE mount-while-exclusive=%d\n", mr);
        sleep(1);
    }

    memset(cdb, 0, 16); cdb[0]=0xF0; cdb[1]=0x00; cdb[2]=0x02; cdb[14]=0x4F; cdb[15]=0x54;
    IOReturn r = readCmd(device, cdb, big, 64, &st, &tr);
    printf("NATIVE bus: r=0x%x st=%u tr=%llu\n", r, st, (unsigned long long)tr);

    memset(cdb, 0, 16); cdb[0]=0xF0; cdb[1]=0x00; cdb[2]=0x00; cdb[14]=0x4F; cdb[15]=0x54;
    r = readCmd(device, cdb, big, 12, &st, &tr);
    printf("NATIVE ic: r=0x%x st=%u tr=%llu\n", r, st, (unsigned long long)tr);

    memset(cdb, 0, 16); cdb[0]=0xE0; cdb[1]=0x15; cdb[2]=0x01; cdb[14]=0x4F; cdb[15]=0x54;
    r = readCmd(device, cdb, big, 512, &st, &tr);
    printf("NATIVE lic: r=0x%x st=%u tr=%llu\n", r, st, (unsigned long long)tr);

    uint8_t rh[16];
    int online = 0;
    for (int i = 0; i < 50; i++) {
        memset(rh, 0, sizeof(rh));
        memset(cdb, 0, 16); cdb[0]=0xD8; cdb[1]=0x00; cdb[2]=0x03; cdb[5]=0x7F; cdb[8]=0x01; cdb[14]=0x4F; cdb[15]=0x54;
        r = readCmd(device, cdb, rh, 16, &st, &tr);
        printf("NATIVE d8[%d]: r=0x%x st=%u tr=%llu data=", i, r, st, (unsigned long long)tr);
        for (int j=0;j<16;j++) printf("%02x", rh[j]);
        printf("\n");
        if (st == 0 && rh[0] == 7) { online = 1; break; }
        usleep(100000);
    }
    if (!online) printf("NATIVE: never reached online 7\n");

    if (!skipRead) {
        memset(big, 0, 0x10000);
        memset(cdb, 0, 16); cdb[0]=0xD9; cdb[1]=0x28; cdb[2]=0x64; cdb[14]=0x4F; cdb[15]=0x54;
        r = readCmd(device, cdb, big, 0x10000, &st, &tr);
        printf("NATIVE pre-read: r=0x%x st=%u tr=%llu hdr=%u,%u,%u,%u,%u type=%02x\n", r, st, (unsigned long long)tr,
               *(uint32_t*)big, *(uint32_t*)(big+4), *(uint32_t*)(big+8), *(uint32_t*)(big+12), *(uint32_t*)(big+16), big[0x14]);
        printf("NATIVE pre-read payload: ");
        for (int i=0;i<64;i++) printf("%02x", big[0x14+i]);
        printf("\n");
    }

    int doLogin = getenv("KMLINK_LOGIN") != NULL;
    if (doLogin) {
        static const uint8_t a1[44] = {
            0xa1,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00,0x03,0x00,0x00,0x00,0x00,0x4f,0x53,0x56,0x45,0x52,0x53,0x49,
            0x4f,0x4e,0x10,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
        };
        uint8_t *lf = calloc(1, 0x10000);
        uint32_t *lh = (uint32_t *)lf;
        lh[0]=1; lh[1]=1; lh[2]=0; lh[3]=1; lh[4]=44;
        memcpy(lf+0x14, a1, 44);
        uint8_t lp[16] = {0xD9,0x2A,0xFF,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
        SCSITaskStatus lst=0; UInt64 ltr=0;
        IOReturn lr = sendFrameAsync(device, lp, lf, 0x10000, &lst, &ltr);
        printf("LOGIN send: r=0x%x st=%u tr=%llu\n", lr, lst, (unsigned long long)ltr);
        free(lf);
        usleep(300000);
        memset(big, 0, 0x10000);
        uint8_t rcdb[16] = {0xD9,0x28,0x64,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
        SCSITaskStatus rst=0; UInt64 rtr=0;
        readCmd(device, rcdb, big, 0x10000, &rst, &rtr);
        printf("LOGIN ack: st=%u tr=%llu hdr=%u,%u,%u,%u,%u\n", rst, (unsigned long long)rtr,
               *(uint32_t*)big, *(uint32_t*)(big+4), *(uint32_t*)(big+8), *(uint32_t*)(big+12), *(uint32_t*)(big+16));
    }
    const char *inner =
        "<OTIMSG><Param_Clipboard_Info_2><OTIMSG>"
        "<CP_Content>4B004D004C0049004E004B002D004E00410054004900560045000A000000</CP_Content>"
        "<CB_Format_Type>CB_Format_Text</CB_Format_Type>"
        "</OTIMSG></Param_Clipboard_Info_2>"
        "<NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>"
        "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
        "</OTIMSG>";
    char env[4096];
    snprintf(env, sizeof(env), "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam>%s</ExtraXmlParam>", inner);
    uint32_t envLen = (uint32_t)strlen(env);
    uint32_t payloadLen = 5 + envLen;
    uint8_t *frame = calloc(1, 0x10000);
    uint32_t *h = (uint32_t *)frame;
    h[0]=1; h[1]=doLogin?2:1; h[2]=0; h[3]=1; h[4]=payloadLen;
    frame[0x14]=0x39;
    *(uint32_t *)(frame+0x15)=payloadLen-5;
    memcpy(frame+0x19, env, envLen);
    uint8_t put[16] = {0xD9,0x2A,0xFF,0,0,0,0,0,0,0,0,0,0,0,0x4F,0x54};
    SCSITaskStatus wst=0; UInt64 wtr=0;
    IOReturn wr = sendFrame(device, put, frame, 0x10000, &wst, &wtr);
    printf("NATIVE send: r=0x%x st=%u tr=%llu payload=%u\n", wr, wst, (unsigned long long)wtr, payloadLen);
    free(frame);

    sleep(1);
    memset(big, 0, 0x10000);
    r = readCmd(device, cdb, big, 0x10000, &st, &tr);
    printf("NATIVE post-read: r=0x%x st=%u tr=%llu head=", r, st, (unsigned long long)tr);
    for (int i=0;i<20;i++) printf("%02x", big[i]);
    printf(" mirror=%s\n", memcmp(big, big+0xFFEC, 20)==0 ? "MATCH":"DIFF");
    printf("NATIVE post payload=%u type=%02x\n", *(uint32_t *)(big+16), big[0x14]);
    printf("NATIVE post head: ");
    for (int i=0;i<0x100;i++) printf("%02x", big[i]);
    printf("\n");
    printf("NATIVE post ascii: ");
    for (int i=0;i<0x100;i++) { unsigned char c=big[i]; putchar(c>=32&&c<127?c:'.'); }
    printf("\n");
    for (int i=0;i+6<0x10000;i++) if (!memcmp(big+i,"OTIMSG",6)) { printf("NATIVE XML@0x%x: ", i); for (int j=0;j<300;j++){unsigned char c=big[i+j]; putchar(c>=32&&c<127?c:'.');} printf("\n"); break; }
    free(big);
    return 0;
}


static volatile int g_daDone = 0;
static void daUnmountCb(DADiskRef disk, DADissenterRef dissenter, void *ctx) {
    (void)disk; (void)ctx;
    g_daDone = 1;
    if (dissenter) printf("DA unmount dissenter status=%d\n", DADissenterGetStatus(dissenter));
}
static int daUnmount(const char *bsd) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return -1;
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd);
    if (!disk) { CFRelease(session); return -2; }
    g_daDone = 0;
    DADiskUnmount(disk, kDADiskUnmountOptionForce, daUnmountCb, NULL);
    for (int i = 0; i < 50 && !g_daDone; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    int ok = g_daDone;
    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);
    return ok ? 0 : -3;
}

int main(int argc, char **argv) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    if (!matching) { printf("no matching dict\n"); return 1; }
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, CFSTR("SCSITaskDeviceCategory"), CFSTR("SCSITaskAuthoringDevice"));
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), props);

    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) { printf("matching failed 0x%x\n", kr); return 1; }

    io_service_t service = 0;
    const char *wantBsd = getenv("KMLINK_BSD");
    int listOnly = getenv("KMLINK_LIST") != NULL;
    io_service_t s;
    while ((s = IOIteratorNext(iterator))) {
        io_name_t nm = {0}; IORegistryEntryGetName(s, nm);
        CFTypeRef bsd = IORegistryEntryCreateCFProperty(s, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        char bname[64] = "(none)";
        if (bsd) { CFStringGetCString(bsd, bname, sizeof(bname), kCFStringEncodingUTF8); CFRelease(bsd); }
        printf("SCSI service bsd=%s name=%s\n", bname, nm);
        if (!service && (listOnly || !wantBsd || !strcmp(bname, wantBsd))) service = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(iterator);
    if (listOnly) return 0;
    if (!service) { printf("no matching SCSITask service\n"); return 1; }

    io_name_t name = {0}, cls = {0};
    IORegistryEntryGetName(service, name);
    IOObjectGetClass(service, cls);
    printf("service: %s class: %s\n", name, cls);

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(service, kIOMMCDeviceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) {
        printf("MMC plugin create failed 0x%x\n", kr);
        IOObjectRelease(service);
        return 1;
    }

    MMCDeviceInterface **mmc = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID),
                                           (LPVOID *)&mmc);
    if (hr != S_OK || !mmc) {
        printf("MMC QueryInterface failed 0x%x\n", (unsigned)hr);
        (*plugin)->Release(plugin);
        IOObjectRelease(service);
        return 1;
    }
    printf("MMC interface acquired\n");

    SCSITaskDeviceInterface **device = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    if (!device) {
        printf("GetSCSITaskDeviceInterface failed\n");
        (*mmc)->Release(mmc);
        (*plugin)->Release(plugin);
        IOObjectRelease(service);
        return 1;
    }
    printf("SCSITask interface acquired\n");

    printf("exclusive available: %s\n", (*device)->IsExclusiveAccessAvailable(device) ? "yes" : "no");
    if (getenv("KMLINK_DA_UNMOUNT")) {
        printf("DA unmount disk5s0=%d\n", daUnmount("disk5s0"));
        printf("DA unmount disk4=%d\n", daUnmount("disk4"));
    }
    IOReturn result = (*device)->ObtainExclusiveAccess(device);
    printf("ObtainExclusiveAccess: 0x%x\n", result);
    if (result != kIOReturnSuccess) {
        (*device)->Release(device);
        (*mmc)->Release(mmc);
        (*plugin)->Release(plugin);
        IOObjectRelease(service);
        return 2;
    }

    if (argc > 1 && !strcmp(argv[1], "--native-early")) {
        (*device)->AddCallbackDispatcherToRunLoop(device, CFRunLoopGetCurrent());
        nativeSend(device, 0);
        (*device)->ReleaseExclusiveAccess(device);
        (*device)->Release(device);
        return 0;
    }

    SCSITaskInterface **task = (*device)->CreateSCSITask(device);
    if (!task) {
        printf("CreateSCSITask failed\n");
    

    int setMode = -1;
    if (argc > 2 && !strcmp(argv[1], "--set-mode")) setMode = (int)strtol(argv[2], NULL, 0);
    if (setMode >= 0) {
        uint8_t cdb[16] = {0xD9, 0x60, 0x01, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        cdb[3] = (uint8_t)setMode;
        SCSITaskStatus st = 0;
        IOReturn r = sendNoData(device, cdb, &st);
        printf("SET_MODE 0x%02x: result=0x%x status=%u\n", setMode, r, st);
        sleep(1);
    }

    int doXmlFlag = (argc > 1 && !strcmp(argv[1], "--send-xml"));
    if (doXmlFlag) {
        uint8_t lic[512]; memset(lic, 0, sizeof(lic));
        uint8_t licCdb[16] = {0xE0, 0x15, 0x01, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus lst = 0; UInt64 ltr = 0;
        IOReturn lr = readCmd(device, licCdb, lic, sizeof(lic), &lst, &ltr);
        printf("LICENSE: result=0x%x status=%u transferred=%llu first=%02x%02x\n", lr, lst,
               (unsigned long long)ltr, lic[0], lic[1]);
        uint8_t rh[16];
        for (int i = 0; i < 8; i++) {
            memset(rh, 0, sizeof(rh));
            uint8_t rhCdb[16] = {0xD8, 0x00, 0x03, 0x00, 0x00, 0x7F, 0x00, 0x00, 0x01, 0,0,0,0,0, 0x4F, 0x54};
            SCSITaskStatus rst = 0; UInt64 rtr = 0;
            IOReturn rr = readCmd(device, rhCdb, rh, sizeof(rh), &rst, &rtr);
            printf("REMOTE[%d]: result=0x%x status=%u transferred=%llu data=", i, rr, rst, (unsigned long long)rtr);
            for (int j=0;j<16;j++) printf("%02x", rh[j]);
            printf("\n");
            usleep(200000);
        }
    }
    int doXml = (argc > 1 && !strcmp(argv[1], "--send-xml"));
    if (doXml) {
        const char *inner =
            "<OTIMSG><Param_Clipboard_Info_2><OTIMSG>"
            "<CP_Content>4B004D004C0049004E004B002D004E00410054004900560045000A000000</CP_Content>"
            "<CB_Format_Type>CB_Format_Text</CB_Format_Type>"
            "</OTIMSG></Param_Clipboard_Info_2>"
            "<NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>"
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            "</OTIMSG>";
        char env[4096];
        snprintf(env, sizeof(env),
                 "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam>%s</ExtraXmlParam>", inner);
        uint32_t envLen = (uint32_t)strlen(env);
        uint32_t payloadLen = 5 + envLen;
        uint8_t *frame = calloc(1, 0x10000);
        uint32_t *h = (uint32_t *)frame;
        h[0] = 1; h[1] = 1; h[2] = 0; h[3] = 1; h[4] = payloadLen;
        frame[0x14] = 0x39;
        *(uint32_t *)(frame + 0x15) = payloadLen - 5;
        memcpy(frame + 0x19, env, envLen);
        uint8_t put[16] = {0xD9, 0x2A, 0xFF, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus wst = 0; UInt64 wtr = 0;
        IOReturn wr = sendFrame(device, put, frame, 0x10000, &wst, &wtr);
        printf("SEND_REAL: payload=%u env=%u result=0x%x status=%u transferred=%llu\n",
               payloadLen, envLen, wr, wst, (unsigned long long)wtr);
        free(frame);
        sleep(1);
        uint8_t *rb = calloc(1, 0x10000);
        SCSITaskInterface **t = (*device)->CreateSCSITask(device);
        SCSITaskSGElement sg = { (uint64_t)(uintptr_t)rb, 0x10000 };
        SCSI_Sense_Data sn; memset(&sn, 0, sizeof(sn));
        SCSITaskStatus st = 0; UInt64 tr = 0;
        uint8_t get[16] = {0xD9, 0x28, 0x64, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        (*t)->SetTaskAttribute(t, (SCSITaskAttribute)0);
    (*t)->SetCommandDescriptorBlock(t, get, 16);
        (*t)->SetScatterGatherEntries(t, &sg, 1, 0x10000, kSCSIDataTransfer_FromTargetToInitiator);
        (*t)->SetTimeoutDuration(t, 2000);
        (*t)->SetAutoSenseDataBuffer(t, &sn, sizeof(sn));
        IOReturn rr = (*t)->ExecuteTaskSync(t, NULL, &st, &tr);
        printf("AFTER_REAL: result=0x%x status=%u transferred=%llu head=", rr, st, (unsigned long long)tr);
        for (int i=0;i<20;i++) printf("%02x", rb[i]);
        printf(" mirror=%s\n", memcmp(rb, rb+0xFFEC, 20)==0 ? "MATCH":"DIFF");
        for (int i=0;i+7<0x10000;i++) {
            if (!memcmp(rb+i,"OTIMSG",6)) {
                printf("XML_AT_0x%x: ", i);
                for (int j=0;j<200 && i+j<0x10000;j++) { unsigned char c=rb[i+j]; putchar(c>=32&&c<127?c:'.'); }
                printf("\n");
                break;
            }
        }
        (*t)->Release(t); free(rb);
    }
    int doWrite = (argc > 1 && !strcmp(argv[1], "--send-test"));
    if (doWrite) {
        uint8_t *frame = calloc(1, 0x10000);
        uint32_t *h = (uint32_t *)frame;
        h[0] = 1; h[1] = 0x12345678; h[2] = 0; h[3] = 1; h[4] = 0x0B;
        uint8_t *p = frame + 0x14;
        p[0] = 0x01; p[1] = 0x07; p[2] = 0xa8; p[3] = 0x03; p[4] = 0x06;
        memcpy(p + 5, "WINPC1", 6);
        for (uint32_t i = 0; i < 0xFFEC - 0x14 - 11; i++) p[11 + i] = (uint8_t)(0x1F + i);
        memcpy(frame + 0xFFEC, frame, 20);
        uint8_t put[16] = {0xD9, 0x2A, 0xFF, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus wst = 0; UInt64 wtr = 0;
        IOReturn wr = sendFrame(device, put, frame, 0x10000, &wst, &wtr);
        printf("SEND_TEST: result=0x%x status=%u transferred=%llu\n", wr, wst, (unsigned long long)wtr);
        free(frame);
    }
    uint8_t mode[16] = {0xD9, 0x60, 0x00, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, mode, 64, "GET_DEVICE_MODE");
    uint8_t side[16] = {0xD9, 0x60, 0x02, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, side, 64, "GET_SIDE_STATUS");
    uint8_t phy[16] = {0xD9, 0x60, 0x04, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, phy, 64, "GET_PHY1_ALIVE");
    uint8_t ic[16] = {0xF0, 0x00, 0x00, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, ic, 12, "GET_IC_VERSION");
    uint8_t bus[16] = {0xF0, 0x00, 0x02, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, bus, 64, "GET_BUS_TYPE");


    uint8_t *big = calloc(1, 0x10000);
    if (big) {
        SCSITaskInterface **t = (*device)->CreateSCSITask(device);
        SCSITaskSGElement sg = { (uint64_t)(uintptr_t)big, 0x10000 };
        SCSI_Sense_Data sn; memset(&sn, 0, sizeof(sn));
        SCSITaskStatus st = 0; UInt64 tr = 0;
        uint8_t get[16] = {0xD9, 0x28, 0x64, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        (*t)->SetTaskAttribute(t, (SCSITaskAttribute)0);
    (*t)->SetCommandDescriptorBlock(t, get, 16);
        (*t)->SetScatterGatherEntries(t, &sg, 1, 0x10000, kSCSIDataTransfer_FromTargetToInitiator);
        (*t)->SetTimeoutDuration(t, 2000);
        (*t)->SetAutoSenseDataBuffer(t, &sn, sizeof(sn));
        IOReturn r = (*t)->ExecuteTaskSync(t, NULL, &st, &tr);
        printf("GET_DATA: result=0x%x status=%u transferred=%llu\n", r, st, (unsigned long long)tr);
        printf("first64: "); for (int i=0;i<64;i++) printf("%02x", big[i]); printf("\n");
        printf("last32:  "); for (int i=0xFFE0;i<0x10000;i++) printf("%02x", big[i]); printf("\n");
        printf("mirror20: %s\n", memcmp(big, big+0xFFEC, 20)==0 ? "MATCH" : "DIFF");
        FILE *dump = fopen("/tmp/oti-getdata.bin", "wb");
        if (dump) { fwrite(big, 1, 0x10000, dump); fclose(dump); }
        for (int i = 0; i + 8 < 0x10000; i++) {
            if (!memcmp(big+i, "<OTIMSG>", 8) || !memcmp(big+i, "OTIMSG", 6) || !memcmp(big+i, "NP_Cmd", 6) || !memcmp(big+i, "Cmd_", 4)) {
                printf("marker at 0x%x: ", i);
                for (int j=0;j<64 && i+j<0x10000;j++) { unsigned char c=big[i+j]; putchar(c>=32&&c<127?c:'.'); }
                printf("\n");
            }
        }
        printf("head256: "); for (int i=0;i<256;i++) printf("%02x", big[i]); printf("\n");
        (*t)->Release(t);
        free(big);
    }
    (*device)->ReleaseExclusiveAccess(device);
        (*device)->Release(device);
        (*mmc)->Release(mmc);
        (*plugin)->Release(plugin);
        IOObjectRelease(service);
        return 1;
    }

    uint8_t inquiry[36];
    memset(inquiry, 0, sizeof(inquiry));
    SCSITaskSGElement sge = { (uint64_t)(uintptr_t)inquiry, sizeof(inquiry) };
    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = 0;
    UInt64 transferred = 0;

    uint8_t cdb[6] = { kSCSICmd_INQUIRY, 0, 0, 0, sizeof(inquiry), 0 };
    (*task)->SetCommandDescriptorBlock(task, cdb, sizeof(cdb));
    (*task)->SetScatterGatherEntries(task, &sge, 1, sizeof(inquiry),
                                     kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);
    (*task)->SetAutoSenseDataBuffer(task, &sense, sizeof(sense));

    result = (*task)->ExecuteTaskSync(task, NULL, &status, &transferred);
    SCSIServiceResponse serviceResponse = 0;
    (*task)->GetSCSIServiceResponse(task, &serviceResponse);
    printf("INQUIRY result=0x%x serviceResponse=%u status=%u transferred=%llu\n",
           result, serviceResponse, status, (unsigned long long)transferred);
    printBytes("sense: ", (const uint8_t *)&sense, sizeof(sense));
    if (transferred >= 36) {
        char vendor[9] = {0}, product[17] = {0}, revision[5] = {0};
        memcpy(vendor, inquiry + 8, 8);
        memcpy(product, inquiry + 16, 16);
        memcpy(revision, inquiry + 32, 4);
        printf("device type=%u vendor=[%s] product=[%s] revision=[%s]\n",
               inquiry[0] & 0x1f, vendor, product, revision);
    }
    printBytes("inquiry: ", inquiry, sizeof(inquiry));

    (*task)->Release(task);

    uint8_t capacity[8];
    memset(capacity, 0, sizeof(capacity));
    SCSITaskInterface **task2 = (*device)->CreateSCSITask(device);
    if (task2) {
        SCSITaskSGElement sge2 = { (uint64_t)(uintptr_t)capacity, sizeof(capacity) };
        uint8_t cdb2[10] = { kSCSICmd_READ_CAPACITY, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        (*task2)->SetCommandDescriptorBlock(task2, cdb2, sizeof(cdb2));
        (*task2)->SetScatterGatherEntries(task2, &sge2, 1, sizeof(capacity),
                                          kSCSIDataTransfer_FromTargetToInitiator);
        (*task2)->SetTimeoutDuration(task2, 5000);
        (*task2)->SetAutoSenseDataBuffer(task2, &sense, sizeof(sense));
        SCSITaskStatus status2 = 0;
        UInt64 transferred2 = 0;
        result = (*task2)->ExecuteTaskSync(task2, NULL, &status2, &transferred2);
        printf("READ_CAPACITY result=0x%x status=%u transferred=%llu\n",
               result, status2, (unsigned long long)transferred2);
        if (transferred2 >= 8) {
            uint32_t lastLBA = ((uint32_t)capacity[0] << 24) | ((uint32_t)capacity[1] << 16) |
                               ((uint32_t)capacity[2] << 8) | capacity[3];
            uint32_t blockSize = ((uint32_t)capacity[4] << 24) | ((uint32_t)capacity[5] << 16) |
                                 ((uint32_t)capacity[6] << 8) | capacity[7];
            printf("lastLBA=%u blockSize=%u\n", lastLBA, blockSize);
    if (argc > 1 && !strcmp(argv[1], "--reset")) {
        uint8_t cdb[16] = {0xF0,0x05,0x02,0x00,0x0A,0,0,0,0,0,0,0,0,0,0x4F,0x54};
        SCSITaskStatus st = 0;
        IOReturn r = sendNoData(device, cdb, &st);
        printf("USB_RESET: r=0x%x st=%u\n", r, st);
        (*device)->ReleaseExclusiveAccess(device);
        (*device)->Release(device);
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "--native")) {
        nativeSend(device, argc > 2 && !strcmp(argv[2], "--noread"));
        (*device)->ReleaseExclusiveAccess(device);
        (*device)->Release(device);
        return 0;
    }
        }
        (*task2)->Release(task2);
    }



    int setMode = -1;
    if (argc > 2 && !strcmp(argv[1], "--set-mode")) setMode = (int)strtol(argv[2], NULL, 0);
    if (setMode >= 0) {
        uint8_t cdb[16] = {0xD9, 0x60, 0x01, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        cdb[3] = (uint8_t)setMode;
        SCSITaskStatus st = 0;
        IOReturn r = sendNoData(device, cdb, &st);
        printf("SET_MODE 0x%02x: result=0x%x status=%u\n", setMode, r, st);
        sleep(1);
    }

    int doXmlFlag = (argc > 1 && !strcmp(argv[1], "--send-xml"));
    if (doXmlFlag) {
        uint8_t lic[512]; memset(lic, 0, sizeof(lic));
        uint8_t licCdb[16] = {0xE0, 0x15, 0x01, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus lst = 0; UInt64 ltr = 0;
        IOReturn lr = readCmd(device, licCdb, lic, sizeof(lic), &lst, &ltr);
        printf("LICENSE: result=0x%x status=%u transferred=%llu first=%02x%02x\n", lr, lst,
               (unsigned long long)ltr, lic[0], lic[1]);
        uint8_t rh[16];
        for (int i = 0; i < 8; i++) {
            memset(rh, 0, sizeof(rh));
            uint8_t rhCdb[16] = {0xD8, 0x00, 0x03, 0x00, 0x00, 0x7F, 0x00, 0x00, 0x01, 0,0,0,0,0, 0x4F, 0x54};
            SCSITaskStatus rst = 0; UInt64 rtr = 0;
            IOReturn rr = readCmd(device, rhCdb, rh, sizeof(rh), &rst, &rtr);
            printf("REMOTE[%d]: result=0x%x status=%u transferred=%llu data=", i, rr, rst, (unsigned long long)rtr);
            for (int j=0;j<16;j++) printf("%02x", rh[j]);
            printf("\n");
            usleep(200000);
        }
    }
    int doXml = (argc > 1 && !strcmp(argv[1], "--send-xml"));
    if (doXml) {
        const char *xml =
            "<OTIMSG><NP_Cmd>Cmd_Get_KM_Switch_Acknowlege</NP_Cmd>"
            "<NP_Up_Notice_NamePipe_Name>\\\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"
            "<Param_Clipboard_Info_2></Param_Clipboard_Info_2></OTIMSG>";
        uint32_t xlen = (uint32_t)strlen(xml);
        uint8_t *frame = calloc(1, 0x10000);
        uint32_t *h = (uint32_t *)frame;
        h[0] = 1; h[1] = 0x22334455; h[2] = 0; h[3] = 1; h[4] = 1 + xlen;
        frame[0x14] = 0x31;
        memcpy(frame + 0x15, xml, xlen);
        memcpy(frame + 0xFFEC, frame, 20);
        uint8_t put[16] = {0xD9, 0x2A, 0xFF, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus wst = 0; UInt64 wtr = 0;
        IOReturn wr = sendFrame(device, put, frame, 0x10000, &wst, &wtr);
        printf("SEND_XML: len=%u result=0x%x status=%u transferred=%llu\n", xlen, wr, wst, (unsigned long long)wtr);
        free(frame);
        sleep(1);
        uint8_t *rb = calloc(1, 0x10000);
        SCSITaskInterface **t = (*device)->CreateSCSITask(device);
        SCSITaskSGElement sg = { (uint64_t)(uintptr_t)rb, 0x10000 };
        SCSI_Sense_Data sn; memset(&sn, 0, sizeof(sn));
        SCSITaskStatus st = 0; UInt64 tr = 0;
        uint8_t get[16] = {0xD9, 0x28, 0x64, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        (*t)->SetTaskAttribute(t, (SCSITaskAttribute)0);
    (*t)->SetCommandDescriptorBlock(t, get, 16);
        (*t)->SetScatterGatherEntries(t, &sg, 1, 0x10000, kSCSIDataTransfer_FromTargetToInitiator);
        (*t)->SetTimeoutDuration(t, 2000);
        (*t)->SetAutoSenseDataBuffer(t, &sn, sizeof(sn));
        IOReturn rr = (*t)->ExecuteTaskSync(t, NULL, &st, &tr);
        printf("AFTER_XML: result=0x%x status=%u transferred=%llu head=", rr, st, (unsigned long long)tr);
        for (int i=0;i<20;i++) printf("%02x", rb[i]);
        printf(" mirror=%s\n", memcmp(rb, rb+0xFFEC, 20)==0 ? "MATCH":"DIFF");
        for (int i=0;i+7<0x10000;i++) {
            if (!memcmp(rb+i,"OTIMSG",6)) {
                printf("XML_AT_0x%x: ", i);
                for (int j=0;j<160 && i+j<0x10000;j++) { unsigned char c=rb[i+j]; putchar(c>=32&&c<127?c:'.'); }
                printf("\n");
                break;
            }
        }
        (*t)->Release(t); free(rb);
    }
    int doWrite = (argc > 1 && !strcmp(argv[1], "--send-test"));
    if (doWrite) {
        uint8_t *frame = calloc(1, 0x10000);
        uint32_t *h = (uint32_t *)frame;
        h[0] = 1; h[1] = 0x12345678; h[2] = 0; h[3] = 1; h[4] = 0x0B;
        uint8_t *p = frame + 0x14;
        p[0] = 0x01; p[1] = 0x07; p[2] = 0xa8; p[3] = 0x03; p[4] = 0x06;
        memcpy(p + 5, "WINPC1", 6);
        for (uint32_t i = 0; i < 0xFFEC - 0x14 - 11; i++) p[11 + i] = (uint8_t)(0x1F + i);
        memcpy(frame + 0xFFEC, frame, 20);
        uint8_t put[16] = {0xD9, 0x2A, 0xFF, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        SCSITaskStatus wst = 0; UInt64 wtr = 0;
        IOReturn wr = sendFrame(device, put, frame, 0x10000, &wst, &wtr);
        printf("SEND_TEST: result=0x%x status=%u transferred=%llu\n", wr, wst, (unsigned long long)wtr);
        free(frame);
    }
    uint8_t mode[16] = {0xD9, 0x60, 0x00, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, mode, 64, "GET_DEVICE_MODE");
    uint8_t side[16] = {0xD9, 0x60, 0x02, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, side, 64, "GET_SIDE_STATUS");
    uint8_t phy[16] = {0xD9, 0x60, 0x04, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, phy, 64, "GET_PHY1_ALIVE");
    uint8_t ic[16] = {0xF0, 0x00, 0x00, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, ic, 12, "GET_IC_VERSION");
    uint8_t bus[16] = {0xF0, 0x00, 0x02, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
    runVendor(device, bus, 64, "GET_BUS_TYPE");


    uint8_t *big = calloc(1, 0x10000);
    if (big) {
        SCSITaskInterface **t = (*device)->CreateSCSITask(device);
        SCSITaskSGElement sg = { (uint64_t)(uintptr_t)big, 0x10000 };
        SCSI_Sense_Data sn; memset(&sn, 0, sizeof(sn));
        SCSITaskStatus st = 0; UInt64 tr = 0;
        uint8_t get[16] = {0xD9, 0x28, 0x64, 0,0,0,0,0,0,0,0,0,0,0, 0x4F, 0x54};
        (*t)->SetTaskAttribute(t, (SCSITaskAttribute)0);
    (*t)->SetCommandDescriptorBlock(t, get, 16);
        (*t)->SetScatterGatherEntries(t, &sg, 1, 0x10000, kSCSIDataTransfer_FromTargetToInitiator);
        (*t)->SetTimeoutDuration(t, 2000);
        (*t)->SetAutoSenseDataBuffer(t, &sn, sizeof(sn));
        IOReturn r = (*t)->ExecuteTaskSync(t, NULL, &st, &tr);
        printf("GET_DATA: result=0x%x status=%u transferred=%llu\n", r, st, (unsigned long long)tr);
        printf("first64: "); for (int i=0;i<64;i++) printf("%02x", big[i]); printf("\n");
        printf("last32:  "); for (int i=0xFFE0;i<0x10000;i++) printf("%02x", big[i]); printf("\n");
        printf("mirror20: %s\n", memcmp(big, big+0xFFEC, 20)==0 ? "MATCH" : "DIFF");
        FILE *dump = fopen("/tmp/oti-getdata.bin", "wb");
        if (dump) { fwrite(big, 1, 0x10000, dump); fclose(dump); }
        for (int i = 0; i + 8 < 0x10000; i++) {
            if (!memcmp(big+i, "<OTIMSG>", 8) || !memcmp(big+i, "OTIMSG", 6) || !memcmp(big+i, "NP_Cmd", 6) || !memcmp(big+i, "Cmd_", 4)) {
                printf("marker at 0x%x: ", i);
                for (int j=0;j<64 && i+j<0x10000;j++) { unsigned char c=big[i+j]; putchar(c>=32&&c<127?c:'.'); }
                printf("\n");
            }
        }
        printf("head256: "); for (int i=0;i<256;i++) printf("%02x", big[i]); printf("\n");
        (*t)->Release(t);
        free(big);
    }
    (*device)->ReleaseExclusiveAccess(device);
    (*device)->Release(device);
    (*mmc)->Release(mmc);
    (*plugin)->Release(plugin);
    IOObjectRelease(service);
    printf("done\n");
    return 0;
}
