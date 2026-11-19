# MacKMLink USB 协议笔记

> 注：本文按时间顺序记录早期协议抓包与内核通道试错过程（含 §18 后来放弃的 DriverKit 实验）。最终方案与纠偏结论请结合 [`NATIVE-SCSI-TRANSPORT.md`](NATIVE-SCSI-TRANSPORT.md)、[`KM-MOUSE-RE.md`](KM-MOUSE-RE.md) 与 [`IMPLEMENTATION-NOTES.md`](IMPLEMENTATION-NOTES.md) 阅读。

## 1. 传输栈

```
应用层  <OTIMSG> XML（SimpleXML / MRS）
  ↓
OTiTransfer: 64 KB 环形缓冲（0x10000，有效 0xFFEC）
  ↓
SCSI vendor CDB（opcode D8/D9/E0/E1/F0/F1，16 字节，末尾 "OT"）
  ↓
USB Mass Storage BOT（class 8/6/0x50，VID 0x0EA0, PID 0x2213）
```

## 2. 64 KB 帧

`GetData`/`PutData` 每次固定 0x10000 字节，其中：

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 20 | 头 |
| 20 (0x14) | 0xFFD8 | 载荷 |
| 0xFFEC | 20 | 头部镜像 |

头部字段（小端 u32）：

| 偏移 | 观察值 | 说明 |
|---|---|---|
| 0 | 1 | 固定 |
| 4 | 递增计数 | 每读一次 +1 左右 |
| 8 | 0 | `HasXMLPackageToSend` 要求为 0 |
| 12 | 1 | `HasXMLPackageToSend` 要求为 1 |
| 16 | 0x0B（空闲） | **载荷长度**（空闲 = 11 = 1 + 4 + "WINPC1"） |
| 20 | 1（空闲） | 载荷首字节：有效 XML 类型为 `0x0F/0x11/0x31` |

判定规则：

- 头部全 0 → 空。
- 首 20 字节与 0xFFEC 处 20 字节一致 → 有效数据。
- 否则 `requestResendPacket`，最多重试 5 次。

空闲载荷实测：

```
01 07 a8 03 06 "WINPC1" 1f 20 21 22 ... (0x1F..0xFF 循环)
```

## 3. uPipe XML

`SimpleXML GetXML` 生成：

```
<OTIMSG>
  <Key1>Value1</Key1>
  <Key2>Value2</Key2>
</OTIMSG>
```

- 值转义：`&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&dq;`
- 键不转义。

`IUPipeCmd PostToRemote` 的固定字段：

```xml
<OTIMSG>
  <NP_Cmd>Cmd_...</NP_Cmd>
  <NP_Up_Notice_NamePipe_Name>\\.\pipe\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>
  <Param_Clipboard_Info_2>...</Param_Clipboard_Info_2>
</OTIMSG>
```

应用层还可能追加：

```xml
<ExtraXmlCommand>HookAppService</ExtraXmlCommand>
<ExtraXmlParam>...</ExtraXmlParam>
```

已知命令名：

- `Cmd_Notify_KM_Switch_To_Remote`
- `Cmd_Notify_KM_Switch_To_Local`
- `Cmd_Force_Remote_To_Switch_Local`
- `Cmd_Get_KM_Switch_Acknowlege`
- `Cmd_Notify_Remote_To_Switch_Back`

## 4. SCSI 命令（16 字节 CDB）

完整表见 [USB.md](USB.md)。数据通道：

| 操作 | CDB | 方向 |
|---|---|---|
| 写数据 | `D9 2A FF ... 4F 54` | OUT |
| 读数据 | `D9 28 64 ... 4F 54` | IN |
| HID 包 | `D9 00 <'3'/'4'/'6'> <12B> ... 4F 54` | OUT |

## 5. 硬件写实验（已做）

| 命令 | 结果 |
|---|---|
| `D9 2A` + 空闲图样 | CHECK CONDITION，sense `70 00 09 ... 85 00`（厂商自定义） |
| `D9 2A` + `<OTIMSG>`（type 0x31） | 同上 `09/85` |
| `D9 60 01 08` | CHECK CONDITION，sense `70 00 05 ... 20 00`（非法 opcode） |

- 失败后设备进入 BOT 错误态，下一次 `D9 28` 会把 CBW 当数据返回；
  关闭并重新打开 SCSITask 用户客户端即可恢复（无需拔线）。
- 说明 `D9 2A` 不是单纯靠 mode 切换就能写，前面还缺链路握手/锁/在线状态。

## 6. OTiTransfer C API（研究工具）

`tools/oti_helper.c` 直接调用原版框架，用于 dump 真实帧：

| API | 说明 |
|---|---|
| `int OTi_Open(void)` | 初始化并独占设备，返回 1 成功 |
| `int OTi_ReadData(void *buffer)` | **参数是 64 KB 缓冲区指针**，返回读到的字节数或 -1 |
| `int OTi_SendData(const void *buffer)` | 从 buffer 拷贝 0xFFEC 字节写入发送流 |
| `void OTi_Close(void)` | 释放独占并恢复媒体 |

运行条件：

1. helper 必须是 `.app`，且 `Contents/Frameworks/OTiTransfer.framework` 存在
   （框架从该路径读 `idVendor=3744` / `idProduct=8723`）。
2. 介质要先挂载（`diskutil mount /dev/disk5s0`），`OTi_Open` 自己卸载；
   提前卸载会报 `Unmount media failed`。
3. 实测 `OTi_Open=1`，`OTi_ReadData` 无数据时返回 -1，`OTi_Close` 正常。

**关键坑**：

- `OTi_SendData` 不能传原始 XML：`PutData` 会按 64 KB 帧处理，
  原始 XML 让 ASCII 当长度做 `CFDataReplaceBytes`，直接断言崩溃。
- 即使传完整 64 KB 帧（20B 头 + 载荷 + 镜像），在 helper 里仍会在
  `PutData` 的 `CFDataReplaceBytes` 断言。原因是 helper 缺少原版 app 的
  runloop/初始化上下文，`OTiTransporter::ProcessIdleState` 后台线程
  对 `self+0x70` 的 CFData 长度处理不一致。
- 结论：helper 适合做**接收/初始化验证**，不适合作为发送端。
  发路径仍需原版 app 或真实抓包。

## 7. 成功发送的真实 64 KB 帧（interpose OTi_SendData 捕获）

```text
偏移 0x00  20B 头:
  01 00 00 00   // 固定 1
  01 00 00 00   // 序号
  00 00 00 00   // 固定 0
  01 00 00 00   // 固定 1
  c3 01 00 00   // 载荷长度 = 451

偏移 0x14  载荷:
  39            // 类型 0x39 = XML 命令
  00 00 01 be   // u32 = 446 = 载荷长度 - 5
  <ExtraXmlCommand>HookAppService</ExtraXmlCommand>
  <ExtraXmlParam>
    <OTIMSG>...</OTIMSG>
  </ExtraXmlParam>
```

- 载荷长度 = `1 + 4 + len(Envelope)`。
- `u32` = `载荷长度 - 5`。
- 发送帧 **不需要** 0xFFEC 镜像；帧尾是未初始化数据。
- 第二个全零 64 KB 帧是空/心跳包，类型 0。

完整 envelope：

```xml
<ExtraXmlCommand>HookAppService</ExtraXmlCommand>
<ExtraXmlParam>
  <OTIMSG>
    <Param_Clipboard_Info_2>
      <OTIMSG>
        <CP_Content>...</CP_Content>
        <CB_Format_Type>CB_Format_Text</CB_Format_Type>
      </OTIMSG>
    </Param_Clipboard_Info_2>
    <NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>
    <NP_Up_Notice_NamePipe_Name>\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>
  </OTIMSG>
</ExtraXmlParam>
```

## 8. 真实报文（daemon 日志捕获）

剪贴板发送时 daemon 构造的完整 XML：

```xml
<OTIMSG>
  <Param_Clipboard_Info_2>
    <OTIMSG>
      <CP_Content>4B004D004C0049004E004B002D0043004C00490050002D0054004500530054000A000000</CP_Content>
      <CB_Format_Type>CB_Format_Text</CB_Format_Type>
    </OTIMSG>
  </Param_Clipboard_Info_2>
  <NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>
  <NP_Up_Notice_NamePipe_Name>\\.\\pipe\\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>
</OTIMSG>
```

- `CP_Content` 是 UTF-16LE 十六进制，末尾 `0000`。
- `CB_Format_Type` 文本为 `CB_Format_Text`。
- 元素顺序：`Param_Clipboard_Info_2`、`NP_Cmd`、`NP_Up_Notice_NamePipe_Name`。
- 同一条消息里可以嵌套 `<OTIMSG>`。

发送失败的 daemon 日志：

```
[ExecuteTaskSync fail] task status: 2
Sense Key byte2=9 byte12=133 byte13=0
otiResult: 85
cdb: 0xd9 0x2a 0xff 0x00 ...
Send Error: others
```

**重要**：原版 daemon 自己发送也得到同样的 `09/85`，说明当前环境不是帧格式问题，
而是桥的链路/TX 状态未就绪（可能被之前的失败写卡住，或 Windows 端未真正在线）。

## 9. IOKit 捕获的完整 CDB 序列（原版 daemon）

interpose `IOConnectCallStructMethod` 后抓到的唯一 CDB：

| 次数 | CDB | 说明 |
|---|---|---|
| 2 | `F0 00 02 ...` | GetBusType，64B IN |
| 4 | `F0 00 00 ...` | GetICVersion，12B IN |
| 1 | `E0 15 01 ...` | license，512B IN |
| 722 | `D8 00 03 00 00 7F 00 00 01 ...` | 远端状态轮询，16B IN |
| 4 | `D8 00 03 00 02 7F 00 00 01 ...` | 远端状态变体 |
| 1 | `D8 00 03 00 04 7F 00 00 01 ...` | 远端状态变体 |
| 8 | `D9 28 64 <addr:4> ...` | 读 64KB |
| 12 | `D9 2A FF ...` | 写 64KB（成功） |

SCSITask 输入结构（59B）：

| 偏移 | 含义 |
|---|---|
| 0 | u32 版本/固定 0 |
| 4 | u32 固定 1 |
| 8 | u8 LUN |
| 9 | CDB[16] |
| 25 | u8 固定 0x10 |
| 26 | u64 传输长度（64 / 12 / 512 / 0x10000） |
| 34 | u8 方向（1=OUT，2=IN） |
| 35 | u16 超时 ms（0x07D0=2000） |
| 42 | u64 缓冲区地址 |
| 50 | u64 已传输字节数 |

## 10. 原生握手实测（干净设备）

```
F0 00 02  -> status 0, 64B
F0 00 00  -> status 0, 12B
E0 15 01  -> status 0, 512B
D8 00 03  -> status 0, data[0]=07 (online)
D9 28 64  -> status 0, 64KB
D9 2A FF  -> status 2, sense 70 00 09 ... 85/86
```

- 预读 `D9 28` 会把 sense 从 `0x85` 推到 `0x86`，但仍不允许 TX。
- `F0 05 02 00 0A`（USB restart）接受但不清 TX 错误态，只有拔插能清。
- 持有独占后 `diskutil mount /dev/disk5s0` 失败（`Failed to find disk`），
  因为 SCSITask 独占会让 BSD 设备节点消失。原版是在独占前创建 DADiskRef，
  独占期间用 `DADiskMount` 挂载；这一步尚未复刻。

## 11. 登录/会话帧（interpose OTi_SendData 完整捕获）

daemon 在新链路建立后、剪贴板之前依次发送：

| seq | type | 长度 | 内容 |
|---|---|---|---|
| 1 | 0xA1 | 44 | 登录，TLV `OSVERSION`（16B 值） |
| 2 | 0xAD | 352 | 本地磁盘/目录列表 |
| 3 | 0xA4 | 693 | 卷列表（Macintosh HD、VM、Preboot…） |
| 4 | 0xA1 | 34 | 登录子命令 0x04 |
| 5 | 0xA2 | 563 | 屏幕/版本二进制信息 |
| 6 | 0x39 | 443 | 剪贴板 XML |
| 7 | 0x39 | 389 | `Cmd_Get_KM_Switch_Acknowlege` + 屏幕尺寸 |

A1 登录帧（44B）：

```
a1 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
03 00 00 00 00 "OSVERSION" 10 00 00 00 <16B 值>
```

每发一帧，daemon 会从 `OTi_ReadData` 收到短 ack（长度 5/4/3/2/1）：

```
01 00 00 00 c7
02 00 00 00
03 00 00
04 00
05
07
```

原生探针在干净状态直接发 A1 仍返回 `09/85`，说明固件要求先有 Windows 侧发起的登录会话，
Mac 单方面发 A1 不会解锁 TX。

## 12. 原生 SCSITask 与 daemon 的结构差异

用同一个 IOKit logger 分别注入 daemon 和原生探针，比较 `D9 2A` 的 SCSITask 输入结构：

```
daemon: 00000000 01000000 00 d92aff... 10000001 00000000 0001 d007 ...
探针:   01000000 01000000 00 d92aff... 10000001 00000000 0001 8813 ...
```

- 偏移 0：daemon `0`，探针 `1`（SCSITask user client ABI 版本/内部字段）；
- 偏移 35：daemon `0x07D0`(2000ms)，探针 `0x1388`(5000ms)，已确认不影响；
- `SetTaskAttribute(kSCSITask_SIMPLE)` 无法把偏移 0 改成 0。

即使完全对齐 CDB、帧格式、DA 卸载顺序、跳过 INQUIRY，原生 `D9 2A` 仍返回 `09/85`。
协议层已一致，卡点是 SCSITask user client 的内核 ABI 差异，不是 uPipe 协议。

## 13. Raw USB BOT 可行性

`IOUSBLib` 实测：

```
USBDeviceOpenSeize           = 0x0        // 设备级可以 seize
USBInterfaceOpenSeize(8/6/80) = 0xe00002c5 // 接口被 IOUSBMassStorageDriver 独占
GetPipeProperties             = 0xe00002cd // 未打开接口，拿不到 bulk 端点
```

- 设备级可以打开，但 mass-storage 接口被内核驱动占用；
- `IOServiceTerminate` 不是用户态 API；
- 没有 root/DriverKit entitlement 就无法在用户态发 Bulk-Only BOT。

## 14. 版本字节补丁实验

在自己的进程里 interpose `IOConnectCallStructMethod`，把 SCSITask 输入结构偏移 0 从 `1` 改成 daemon 的 `0`：

```
LOGIN send: r=0xe00002e2 st=0 tr=0
NATIVE send: r=0x0 st=0 tr=0
```

- 状态从 CHECK CONDITION 变成 GOOD；
- 但 `transferred=0`，登录调用返回 bad argument；
- 说明内核按版本 0 解析的字段布局不同，数据没有真正传输。

这不是可用的修复，只是证明偏移 0 确实影响内核解析。

## 15. Root 权限测试

用 `osascript ... with administrator privileges` 以 root 运行同一个 USB 探针：

```
USBDeviceOpenSeize=0x0
USBInterfaceOpenSeize(cls=8/6/80)=0xe00002c5
```

root 也无法 seize 被 `IOUSBMassStorageDriver` 占用的接口。
要拿接口只能卸载系统 mass-storage 驱动（影响所有 USB 存储），不能作为产品方案。

## 16. arm64 SCSITask user client ABI（2026-10-21 新发现）

反汇编 `SCSITaskLib.plugin` arm64 切片：

```
IOServiceOpen(service, mach_task_self(), 0xC, &conn)   // type = 12
```

scalar selector 实测（type 12 连接）：

```
sel=3  -> 0x0
sel=14 -> 0x0
sel=1/2 -> 0xe00002c2 (bad argument)
sel=6  -> 0xe00002c2（未完成 task 初始化）
```

`SCSITaskClass::ExecuteTask` 构造 selector 6 输入：

```
w3 = 0x2B + 16 * cdbCount
struct[0x00..0x2A] = 43 字节 task 属性
struct[0x2B..]     = 16 字节 CDB（可多个）
```

而 x86_64 daemon 抓到的 59 字节结构是 **CDB 在偏移 9**，与 arm64 的
43+16 布局不兼容。这解释了为什么 arm64 下 `D9 2A` 一直返回
CHECK CONDITION（09/85），而 x86_64 daemon 正常。

## 17. type 12 枚举结果

对 `IOCompactDiscServices` 枚举 `IOServiceOpen` type 0–24：

```
type=12 conn=...
  sel=1 kr=0xe00002c2
  sel=3 kr=0x0
```

- 只有 type 12 能打开；
- selector 3 成功（MMC 类的 exclusive/初始化），selector 1 不支持；
- selector 6 返回 bad argument，说明该连接是 **MMCDeviceUserClientClass**，不是通用 `SCSITaskClass`；
- 虚拟 CD 服务上拿不到通用 SCSITask 通道，直接 SCSITask 路线不可行。

## 18. DriverKit 签名/加载实测（2026-10-21）

1. dext 必须是**扁平布局**：`.dext/KMLinkUSB` + `.dext/Info.plist`，
   可执行文件类型是 **Mach-O executable**（不是 kext bundle）。
   之前用 `-Wl,-kext` + `Contents/MacOS` 导致 codesign 不嵌入 entitlement。
2. 修正后签名成功，entitlement 正确嵌入：

```
com.apple.developer.driverkit = true
com.apple.developer.driverkit.transport.usb = [{idVendor:3744, idProduct:8723}]
TeamIdentifier = <TEAM_ID>
```

3. `systemextensionsctl developer on` 被 SIP 拒绝：
   "cannot be used if System Integrity Protection is enabled"。
4. 带 `com.apple.developer.system-extension.install` 的宿主 app 无法启动：
   launchd `POSIX error 163`，说明受限 entitlement 需要 Apple 签发的
   provisioning profile。
5. 机器上已有第三方 dext（Karabiner，Team G43BCU2T37）正常运行，
   证明只要 entitlement/profile 合法即可加载。

结论：DriverKit 路线代码已就绪，剩余门槛是 Apple 的
`com.apple.developer.driverkit.transport.usb` 授权与带该 entitlement 的
provisioning profile。

## 19. 未决问题

1. 纯原生只剩 DriverKit 系统扩展（需要 Apple entitlement）；root 也无法 seize 被驱动占用的接口。
2. 载荷首字节 `0x0F/0x11/0x31` 与 KM/剪贴板/文件的对应关系。
3. XML 在载荷中的起始偏移（0x14 还是 0x15/0x19）。
4. 发送时是否需要额外的序号/重传状态。

Windows USBPcap 抓包可一次性确认以上四点。
