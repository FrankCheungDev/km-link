# MacKMLink.app 研究记录

> 注：本文件记录项目最早期对原版应用二进制的静态逆向观察（当时尚未打通原生 USB SCSI 通道，第 7 节曾暂定替代路线）。实际工程已采用原生 `SCSITaskLib` 纯 USB 方案，详见 [`NATIVE-SCSI-TRANSPORT.md`](NATIVE-SCSI-TRANSPORT.md) 与 [`IMPLEMENTATION-NOTES.md`](IMPLEMENTATION-NOTES.md)。

本文件记录复刻前的逆向观察。所有结论来自本机安装包及其内嵌载荷的静态检查，
未运行原程序的安装器，也未复用其代码。

## 1. 目标

| 项 | 值 |
|---|---|
| 安装位置 | `/Applications/MacKMLink.app` |
| 外壳版本 | `1.0.1325.52`，x86_64，未签名 |
| 外壳 SHA-256 | `17df2acb283b6315bf061434ff58a97296dbb70bdd95e260035dd038eab27d28` |
| 内嵌载荷 | `Contents/Resources/MacKMLinkFull.tgz`（1.1 MB，150 项） |
| 载荷应用 | `MacKMLink.app` v`2.0.0.7`，`com.oti.MacKMLinkWithGOBridge` |
| 守护进程 | `GoBridgeDemon` v`1.0.00b`，`com.oti.GoBridgeDemon`，LSUIElement |
| 版权 | Oti Technology（与 OTi SmartKM 系列同源） |

外壳只做三件事：解包 `MacKMLinkFull.tgz` 到 `~/Library`（Info.plist 的
`Destination`），拉起 `MacKMLink`，并保留 `GoBridgeDemon` 作为常驻桥接进程。

载荷二进制均为 x86_64（`MacKMLink`、`GoBridgeDemon`、`KMKeyMouse.dylib`、
`KMClipboard.dylib`、`OTiTransfer`、`FileChgEvent.dylib`、`DownloadUpdateTool`），
在 Apple Silicon 上只能经 Rosetta 运行——这正是复刻为 arm64 的动机之一。

## 2. 传输层：USB 桥接线，不是网络

- `OTiTransporter` 通过 `SendSCSICommandSendData` / `SendSCSICommandReceiveData`
  发送厂商自定义 SCSI 命令，`findUsbInterface` / `vendorID` / `USBRestart`
  表明它枚举为 USB 大容量设备并使用私有命令集。
- `SKMBridge` 封装 `uPipe` 消息（`IUPipeCmd`、`GenericUPipeCmd`、
  `supportUPipeMsgCmd:checkForCmd:`），KM、剪贴板、文件都走这条管道。
- 全部二进制中没有 Bonjour、IP、TCP/UDP、NWConnection 等网络符号；
  唯一的 `Network` 字符串是通用词，不是网络模式。
- 因此原版是「USB 数据线 + 对端 Windows 上的 GO! Bridge」的硬件方案。
  本复刻无法在无硬件的情况下兼容其私有 SCSI 协议，改用局域网 TCP。

## 3. 键鼠引擎（`KMKeyMouse.dylib`）

关键符号与结构：

- 捕获：`CGEventTap`（`CFMachPortCreateRunLoopSource`、`GetApplicationEventTarget`）。
- 注入：`CGEventCreateMouseEvent`、`CGEventPost`、`CGWarpMouseCursorPosition`。
- 热键：`RegisterEventHotKey` / `UnregisterEventHotKey`（`OnHotkeyEvent`）。
- 边缘切换：`CKMEvent::DetectSwitch`、`SwitchToRemote`、`SwitchFromRemote`、
  `ProcessSwitchToRemoteCmd`、`SendSwitchToRemoteCmd(x,y,w,h)`，
  以及 `CalculateMouseBackPoint`、`MouseBack`、`warpMouse`、`IsPointInScreen`。
- `CKMEvent` 结构包含：`switch_direction`、`remote_switch_direction`、
  `m_RegisteredHotkeyModifiers`、`m_RegisteredHotkeyKeyCode`、`screenRect`、
  `virtual_screenRect`、`m_bHotKeySwitchOnly`、`m_bInRemoteControl`、
  `m_xCursor/m_yCursor`、加速度与 1ms 鼠标计数等。
- 字符串显示默认热键为 **Alt-S**；UI 可配置「Use Hotkey to switch only」、
  四个方位、屏幕边界容差（Tolence Of Screen Boundary）、灵敏度。
- 支持「点击指定屏幕热区」与「Send Ctrl-Alt-Del to another computer」。

## 4. 剪贴板（`KMClipboard.dylib`）

- `CClipboard` / `IClipboard` 以 `EFormat` 描述格式，经 `uPipe` 编解码
  （`marshallFromUPipeMsg` / `unmarshallFromUPipeMsg`）。
- 含 macOS ↔ Windows 转换器：`COSXClipboardTextConverter`、`UTF16Converter`、
  `AppleBaseConverter`、`WindowsDIBConverter`、`WindowsPPTConverter`、
  `WindowsRTFConverter`、`WindowsHTMLConverter`、`WindowsMultiImageConverter`、
  `FileConverter`。
- 由此可知原版支持文本、RTF、HTML、图片、文件列表的跨平台剪贴板。

## 5. 文件传输（`OTiTransfer` + `GoBridgeDemon`）

`Cmd_*` 命令构成文件穿梭（File Shuttle）协议：

```
Cmd_Drag_File_Is_Beginning        Cmd_Get_Remote_Dragging_Info
Cmd_Late_Send_Drop_Data           Cmd_Cancel_Late_Send_Waiting
Cmd_Delete_Src_Temp_File          Cmd_Move_File_To_Trash
Cmd_Finish_Move_File_To_Trash     Cmd_Transfer_Clipboard
Cmd_Get_Drive_Update_Info         Cmd_Post_Drive_Update_Info
Cmd_Notify_KM_Switch_To_Local     Cmd_Notify_KM_Switch_To_Remote
Cmd_Force_Remote_To_Switch_Local  Cmd_Notify_Remote_To_Switch_Back
Cmd_Get_KM_Switch_Acknowlege      Cmd_Post_Remote_KM_Setting_Info
Cmd_Check_Bridge_Block_Status     Cmd_Replay_Bridge_Block_Status
```

UI 字符串印证：拖拽投放（`drophere`）、进度/替换确认、磁盘空间检查、
Auto Share（自动分享/阻断发送/阻断接收）、临时文件清理。

## 6. 界面与本地化

- Cocoa + Storyboard/NIB（`MainMenu.nib`、`Main.storyboardc`），
  `LSBackgroundOnly`/`LSUIElement` 常驻形态。
- 12 个 `.lproj`（en、zh_CN、zh_TW、ja、ko、de、fr、es、it、pt、ru、tr），
  205 条 `Localizable.strings`。
- 功能面：设备列表、连接信息、KM 控制开关、剪贴板收发开关、自动分享、
  Dock/迷你面板模式、屏幕边缘/热区、辅助功能授权引导、更新检查。

## 7. 复刻的设计决策

| 原版 | 复刻 |
|---|---|
| USB SCSI 私有桥接 | Bonjour + TCP，自定义长度前缀帧 |
| 对端 GO! Bridge（Windows） | 对端 KMLink（macOS），同协议 |
| `CGEventTap` + `CGEventPost` | 保留同一系统机制 |
| Carbon `RegisterEventHotKey` | 保留（⌃⌥S） |
| `uPipe` 剪贴板格式 | Codable JSON + base64 数据，直接映射 NSPasteboard 类型 |
| 文件穿梭命令 | fileOffer/Accept/Reject/Done + 256 KB 分块 |
| x86_64 | arm64（`-target arm64-apple-macos13.0`） |

未复刻：更新器、Dock 模式、Ctrl-Alt-Del、日文键盘布局、Windows 格式转换、
USB 设备管理。

## 8. 证据与边界

- 版本/哈希：见第 1 节；`Info.plist` 的 `Archive`、`Destination`、
  `Demon Bundle Identifier` 直接给出加载链。
- 符号：`nm`/`strings` 等价物由分析脚本直接读取 Mach-O 字节得到；
  方法名与结构体字段来自 Objective-C 运行时元数据。
- 边界：未获得 USB 桥接线的厂商命令格式，也未在 Windows 端抓包；
  因此「与原生 GO! Bridge 互通」不在本次复刻范围内。
