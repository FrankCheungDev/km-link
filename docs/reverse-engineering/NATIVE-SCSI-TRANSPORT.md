# 原生 SCSI 通道（无需 DriverKit entitlement）

## 结论

在 Apple Silicon 上，**不需要** DriverKit entitlement、**不需要** Rosetta，
就可以对 OTi 桥接设备执行厂商标记 SCSI 命令。

已用真实硬件验证：`F0 00 00` 返回 64 字节设备信息，与从原版
`GoBridgeDemon` 抓到的 INQUIRY 回复逐字节一致：

```
00 00 22 13 00 01 30 39 30 33 30 31 ...
      ^PID 0x2213  ^ "090301"
```

## 关键步骤

```c
// 1. dlopen Apple 自带的 SCSITaskLib 插件
void *h = dlopen("/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext"
                 "/Contents/PlugIns/SCSITaskUserClient.kext"
                 "/Contents/PlugIns/SCSITaskLib.plugin/Contents/MacOS/SCSITaskLib",
                 RTLD_NOW | RTLD_LOCAL);
FactoryFn factory = dlsym(h, "SCSITaskLibFactory");

// 2. 调 factory 得到 IOCFPlugInInterface
IOCFPlugInInterface **plugin =
    factory(NULL, kIOSCSITaskDeviceUserClientTypeID);

// 3. 必须手动 Probe + Start，把 service 注入插件
//    （IOCreatePlugInInterfaceForService 内部就是做这两步，
//      但它自己在这台机器上返回 kIOReturnUnsupported）
io_service_t svc = IOServiceGetMatchingService(
    kIOMainPortDefault, IOServiceMatching("IOCompactDiscServices"));
(*plugin)->Probe(plugin, NULL, svc, &score);
(*plugin)->Start(plugin, NULL, svc);   // 内部 IOServiceOpen(service, task, 12, &conn)

// 4. 走文档化接口
SCSITaskDeviceInterface **dev = NULL;
(*plugin)->QueryInterface(plugin,
    CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (void **)&dev);
(*dev)->ObtainExclusiveAccess(dev);
SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
(*task)->SetCommandDescriptorBlock(task, cdb, 16);
(*task)->SetScatterGatherEntries(task, &sg, 1, len, dir);
(*task)->SetTimeoutDuration(task, 5000);
(*task)->ExecuteTaskSync(task, &sense, &status, &realized);
```

## 几个必须知道的坑

1. **目标服务是 `IOCompactDiscServices`**（LUN 1，CDROM，Product Name
   `Android+Mac`），不是 `IOSCSIPeripheralDeviceType00`（LUN 0 的 FAT 卷）。
   - 只能通过 `IOServiceMatching("IOCompactDiscServices")` 拿到；
   - 它带 `SCSITaskDeviceCategory = SCSITaskAuthoringDevice`、
     `IOUserClientClass = SCSITaskUserClient`、
     `IOCFPlugInTypes = {97ABCF2C-...: SCSITaskLib.plugin}`。
   - 之前用 `IOBSDNameMatching("disk4")` 沿父链找全部失败，属于找错节点。

2. **`IOServiceOpen` 的 type 必须是 12**，0–4 全部返回
   `kIOReturnBadArgument`。这个值来自插件反汇编：
   `SCSITaskLib.plugin` 里 `mov w2, #0xc` → `_IOServiceOpen`。

3. **`IOCreatePlugInInterfaceForService` 不可用**，返回
   `kIOReturnUnsupported`；必须 dlopen + factory + Probe + Start。
   x86_64 下同样失败，所以和架构无关。

4. **必须 `ObtainExclusiveAccess`**，否则 `CreateSCSITask` 返回 NULL。
   这会独占 LUN，所以实现里要先卸载 `MacKMLINK` 卷——原版也是这么做的
   （日志里的 `Unmount media failed!!!`）。

## ExecuteTask 结构（selector 6）

原版抓到的 59 字节输入结构，与插件 `SCSITaskClass::ExecuteTask`
（selector 6）一致：

| 偏移 | 字段 |
|---|---|
| 9 | CDB（16 字节） |
| 26 | u32 dataLength |
| 34 | u8 direction（1=out，2=in） |
| 43 | u64 data buffer 指针 |

## 复现

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
clang -target arm64-apple-macos13.0 -isysroot "$SDK" \
  -framework IOKit -framework CoreFoundation \
  -o build/scsitask_final tools/scsitask_final.c
# 先退出原版 MacKMLink 并卸载卷
./build/scsitask_final
```

探针源码：`tools/scsitask_final.c`。
