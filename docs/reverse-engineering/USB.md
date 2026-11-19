# USB 传输层研究记录

> 说明：本篇为早期通道探索记录（包含后来被 `SCSITaskLib` 方案取代的 `IOMMCDevice` 尝试）。最终方案见 [`NATIVE-SCSI-TRANSPORT.md`](NATIVE-SCSI-TRANSPORT.md)。

## 1. 设备

桥接线已在本机枚举（`ioreg -p IOUSB`）：

| 项 | 值 |
|---|---|
| Vendor / Product | `0x0EA0` / `0x2213` |
| 名称 | `Android+Mac` |
| 序列号 | `<device-serial>` |
| 接口 | class 8 / subclass 6 / protocol 0x50（USB Mass Storage, SCSI transparent, Bulk-Only） |
| 内核驱动 | `IOUSBMassStorageDriver` |
| 虚拟介质 | `disk4`（1.1 MB FAT，`NO NAME`）、`disk5`（16.3 MB CD，`MacKMLINK`） |

原版 `GoBridgeDemon`（未签名，由 `MacKMLink` 通过 NSTask 启动）链接
`OTiTransfer.framework`，通过 `SCSITaskDeviceCategory = SCSITaskAuthoringDevice`
找到 `IOSCSIPeripheralDeviceType05`。

## 2. Apple Silicon 用户态访问路径

`IOSCSIPeripheralDeviceType05` 发布的 `IOCFPlugInTypes` 是 **MMC** 类型
（`97ABCF2C-23CC-11D5-A0E8-003065704866`），不是 SCSITask 类型
（`7D66678E-...`）。正确路径：

```
IOCreatePlugInInterfaceForService(service, kIOMMCDeviceUserClientTypeID)
  -> QueryInterface(kIOMMCDeviceInterfaceID)          // MMCDeviceInterface
  -> GetSCSITaskDeviceInterface()                      // 原始 CDB 通道
  -> ObtainExclusiveAccess()
  -> CreateSCSITask() / SetCommandDescriptorBlock / ExecuteTaskSync
```

**前置条件**：必须先卸载 `disk4` 和 `disk5`，否则 `ObtainExclusiveAccess`
返回 `kIOReturnBusy (0xE00002D5)`。原版运行时也会独占设备
（`kIOReturnExclusiveAccess 0xE00002C5`），测试前需退出
`GoBridgeDemon`/`MacKMLink`。

工具：`tools/scsi_probe.c`，构建见文件头。

已实测通过：

```
INQUIRY        device type=5  product=[Android+Mac]  revision=[2.00]
READ_CAPACITY  lastLBA=1964 blockSize=2048
GET_IC_VERSION 12 bytes: 000022130001303930333031
GET_BUS_TYPE   64 bytes（含 "2.00 Oti Inside"）
```

## 3. 厂商 CDB（16 字节，末尾 `4F 54` = "OT"）

从 `OTiTransfer` 反汇编解出（地址为函数入口）：

| 命令 | CDB | 数据 | 来源 |
|---|---|---|---|
| HID 包发送 | `D9 00 <'3'/'4'/'6'> <12B> … 4F 54` | 无 | `sendHIDPacket` 0x3306 |
| 取 IC 版本 | `F0 00 00 … 4F 54` | 12 B | `GetICVersion` 0x4566 |
| 取物理总线/速率 | `F0 00 02 … 4F 54` | 64 B | `GetPhysicalBusType` 0x440e / `GetSpeedStatus` 0x4db0 |
| USB 重启 | `F0 05 02 00 0A … 4F 54` | — | `USBRestart` 0x780e |
| 读锁状态 | `F0 30 … 4F 54` | — | `GetLockStatus` 0x78a4 |
| 锁功能 | `F0 31 01 <mode> <p1> <p2> … 4F 54` | — | `LockFunction` 0x46a0 |
| 取设备模式 | `D9 60 00 … 4F 54` | 64 B | `GetDeviceMode` 0x74a4 |
| 设设备模式 | `D9 60 01 <mode> … 4F 54` | — | `SetDeviceMode` 0x7410 |
| 取侧别状态 | `D9 60 02 … 4F 54` | 64 B | `GetGenderStatus` |
| 取 PHY1 | `D9 60 04 … 4F 54` | 64 B | `GetPHY1Alive` 0x76e6 |
| 取远端主机状态 | `D8 00 03 … 4F 54` | — | `GetRemoteHostStatus` 0x5278 |
| 设远端主机状态 | `D8 01 … 4F 54` | — | `SetRemoteHostStatus` |
| 请求重发 | `D8 0B … 4F 54` | — | `RequestResendPacket` |
| 读数据 | `D9 28 64 … 4F 54` | 变长 | `GetData` |
| 写数据 | `D9 2A FF … 4F 54` | 变长 | `PutData` |
| 拒绝远端发送 | `D9 39 … 4F 54` | — | `RejectRemoteTX` |
| NAND 检测 | `E0 11 … 4F 54` | — | `NandDetectBound` |
| NOR 检测 | `F1 … 4F 54` | — | `NorDetectBound` |
| 读 NOR 表 | `E1 03 <addr:4> 00 <len:2> … 4F 54` | 变长 | `ReadNorInitTable` 0x7b62 |
| License | `E0 15 … 4F 54` | — | `GetLicenseInformation` |

注意：`D9 60 00/02/04` 直接发送会返回 CHECK CONDITION，说明这些 getter
依赖设备已切到链路模式或需要额外字段；目前只有 `F0 00 00` / `F0 00 02`
在 CD 模式下可直接读到有效数据。

## 4. 尚未解决

1. **uPipe 帧格式**：`IUPipeCmd` / `GenericUPipeCmd` / `Cmd_*` 的命令 ID 与
   头部布局；`PutData`/`GetData` 只是字节通道，上层帧仍需还原。
2. **初始化时序**：原版从 CD 模式切到链路模式的完整命令序列。
3. **与 Windows 端互通**：需要原版 Windows GO! Bridge 作为对端。
4. **动态抓帧**：尝试用 `DYLD_INSERT_LIBRARIES` 拦截 `IOConnectCallStructMethod`
   时，因 IOKit 符号被全局替换导致原版在 GPU 初始化阶段崩溃；需要改用
   lldb 断点或 COM vtable 包装。

## 5. 复现命令

```bash
# 退出原版并卸载虚拟介质
pkill -f GoBridgeDemon; pkill -f MacKMLinkFull
diskutil unmountDisk force /dev/disk4
diskutil unmountDisk force /dev/disk5

# 编译并运行探针
clang -target arm64-apple-macos13.0 -isysroot "$SDK" \
  -framework IOKit -framework CoreFoundation -o build/scsi_probe tools/scsi_probe.c
./build/scsi_probe

# 恢复原版
open ~/Library/MacKMLinkFull/MacKMLink.app
```
