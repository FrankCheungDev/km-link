# OTi 文件传输协议逆向记录

> 注：双向文件传输（`0x10` UTF-16BE + `0x3a` / 独立 LE `0xA3` + `0x37` + `0xA7`）已在此后补齐并完成验证，补充总结见 [`IMPLEMENTATION-NOTES.md`](IMPLEMENTATION-NOTES.md)。

目标：补齐纯 USB 模式下的文件拖拽传输。

## 1. 发现

`GoBridgeDemon` 虽然是 Go 命名的 app，但文件传输是 **Objective-C/C++** 实现，包含：

- `THMFileManager`（227 个方法）
- `THMRemoteFileWrapper`
- `WinDriveInfo`
- `MultipleFilePackage`
- `UploadFile` / `DownloadFile` / `UploadMultipleFile` / `DownloadMultipleFile`

相关方法（已定位 IMP）：

```
prepareUploadFiles:toRemotePath:session:   0x100017c67
confirmUploadFilesSync:                    0x100017afd
uploadFiles:toRemotePath:                  0x100018518
uploadMultipleItems:toDest:subDirs:        0x10001b5a9
receiveDownloadFileData:                   0x10001447b
buildRemoteFileListXML:                    0x1000121ae
handleCommand:                             0x10000487f
```

## 2. 已还原的 XML 标签

### 目录列表

```
NodeInfoList
  NodeInfo
```

路径分隔符用 `\` / `/` 区分平台。

### 上传

```
UploadFilesCmd
  UploadFilesDataArray
  UploadRemotePathString
  UploadItemsArray
UploadZeroLengthFilesCmd
  UplooadZeroLengthFilesDataArray   （注意原版拼写就是 Uplooad）
ConfirmFilesCmd
SubDirsDict
```

`prepareUploadFiles:toRemotePath:session:` 负责组装
`UploadFilesCmd` / `UploadFilesDataArray` / `UploadZeroLengthFilesCmd` /
`ConfirmFilesCmd` / `SubDirsDict`。

`uploadFiles:toRemotePath:` 负责 `UploadItemsArray` 和
`UploadRemotePathString`。

### 数据传输 / 下载

```
TransferFileDataCommands
TransferFilePath
FileSessionID
FileDataLength
EstimatedFileSize
DownloadPaths
REMOTE_PATH
REMOTE_WRAPPERS
DownloadError
MultiSessionErrorInformation
UploadError
```

`receiveDownloadFileData:` 依次使用 `TransferFilePath`、
`TransferFileDataCommands`、`FileSessionID`、`FileDataLength`、
`EstimatedFileSize`。

## 3. 推断的流程

### 上传

1. 本地选择文件，生成 `UploadItemsArray`（文件名、长度、属性）；
2. 发送 `UploadFilesCmd` + `UploadRemotePathString`；
3. 零字节文件走 `UploadZeroLengthFilesCmd`；
4. 远端返回 `ConfirmFilesCmd`；
5. 按 `FileSessionID` 分块发送数据，每块带 `TransferFilePath`、
   `FileDataLength`、`EstimatedFileSize`；
6. 结束/错误通过 `UploadError`、`MultiSessionErrorInformation` 回传。

### 下载

1. 远端目录列表（`NodeInfoList`）选择文件；
2. 请求 `DownloadPaths`，得到 `REMOTE_WRAPPERS`；
3. 数据块通过 `TransferFileDataCommands` + `TransferFilePath` +
   `FileDataLength` 下发；
4. 本地写入，完成/错误回传。

## 4. 还没确认

- XML 的精确嵌套和属性名（目前只有标签名，没有完整示例）；
- 文件数据是 **base64/hex 放在 XML**，还是 **独立二进制 packet**
  （daemon 里有 `_PacketData` / `_PacketSize` / `_XmlPacket`，倾向后者）；
- 数据块的 OTi frame payload type（登录/剪贴板是 `0xA1`/`0x39`，
  文件数据可能是另一个 type）；
- 分块大小、确认/重传策略；
- `FileSessionID` 与 `NP_Cmd` 的关系；
- `ConfirmFilesCmd` 的应答格式。

## 5. 下一步：运行时抓包

静态标签不足以还原完整 XML 和二进制布局，需要抓一次真实文件拖拽。

准备：

1. Windows GO! Bridge 保持连接；
2. 退出原版 `MacKMLink` / `GoBridgeDemon`；
3. 挂载 `disk4`/`disk5s0`；
4. 用 `build/streamlog_oti.dylib` 注入 `GoBridgeDemon`：
   ```
   DYLD_INSERT_LIBRARIES=$PWD/build/streamlog_oti.dylib \
     ~/Library/MacKMLinkFull/MacKMLink.app/Contents/PlugIns/GoBridgeDemon.app/Contents/MacOS/GoBridgeDemon -LaunchByShell
   ```
5. 启动原版 shell（或直接操作对端）；
6. 从 Mac 拖一个 **小文本文件** 到 Windows，再从 Windows 拖回一个；
7. 收集 `/tmp/kmlink-oti.log`。

分析重点：

- `SEND len=` 中是否出现 `TransferFileDataCommands`；
- 文件数据块的 payload type 和长度；
- `FileSessionID`、`FileDataLength` 的实际值；
- 是否伴随 `disk4` 卷写入（FAT 邮箱假设）。

## 6. 备选假设

如果抓不到 XML 文件命令，可能是：

1. 文件数据走 **独立 bulk 通道**，不经过 64 KB OTi 帧；
2. 文件通过 **虚拟卷**（`/Volumes/...`）读写，daemon 只做代理；
3. 文件传输只在 **Windows 端主动**时使用另一套命令。

## 7. 2026-10-22 运行时抓包（拖拽开始）

抓包方式：`iokitlog4.dylib` 注入 `GoBridgeDemon`，拦截
`IOConnectCallStructMethod` selector 6，dump CDB 和 64 KB 数据缓冲。

原始日志为本机抓包产物（`iokit.log` / `daemon.log`，不纳入仓库版本控制）。

实际序列：

```
Windows → Mac: Cmd_Get_Remote_Dragging_Info
Mac → Windows: <NodeInfoList>（type 0x39 剪贴板通道）
Mac → Windows: Cmd_Drag_File_Is_Beginning
```

`NodeInfo`（824 字节）：

| 偏移 | 内容 |
|---|---|
| 0..255 | ANSI 路径，NUL 填充：`/\Users\<user>\Downloads\sample-document.docx` |
| 260.. | UTF-16LE 路径，NUL 填充 |
| 尾部 56B | 3 个 FILETIME（创建/修改/访问）+ 文件大小 |

文件大小 `0x2CC3` = 11459，与测试 docx 一致。

**没有捕获到**：`TransferFileDataCommands`、`UploadFilesCmd`、
`ConfirmFilesCmd`、`FileDataLength`，也没有大文件数据帧。

说明这次只完成了“拖拽开始/文件元数据交换”，没有真正把文件内容传给
Windows。要抓数据面，必须让文件在 **Windows 侧松手并落盘**，或反向从
Windows 拖到 Mac 并落盘。

## 8. 第二次抓包（Mac → Windows 成功方向）

第二轮完整拖拽抓包确认：

序列：

```
09:02:16  Windows → Mac: Cmd_Get_Remote_Dragging_Info
09:02:16  Mac → Windows: NodeInfoList（路径 /Users/<user>/Desktop/...docx）
09:02:16  Mac → Windows: Cmd_Drag_File_Is_Beginning
09:02:22  Windows → Mac: DownloadMultipleFile(0x10)
09:02:22  Mac → Windows: 0xa3 帧，payload 前 12B + "PK\x03\x04"（ZIP 头）
```

`0x10` 帧 payload：

```
01 00 cf 0f 25 03 6e 00
UTF-16LE: //Users/<user>/Desktop/sample-document.docx
```

`0xa3` 帧：

```
u32 0x0fcf2503 + 00 00 00 01 + 00 00 00 + 50 4b 03 04 ...
```

只抓到 **219 字节 ZIP 前缀**；11,459 字节的完整 docx 没有出现在
SCSI selector 6 上。`OTiTransfer` 同时引用
`IOUSBInterfaceUserClientV2`，文件主体很可能走 **IOUSBLib bulk pipe**，
不是 SCSI CDB。

### Windows → Mac

两次尝试都没有出现 `Cmd_Get_Remote_Dragging_Info` 或
`Cmd_Drag_File_Is_Beginning`，Mac 侧没有收到任何拖拽元数据，
所以跨屏后拖动标识消失。问题在 Windows 端没有发起拖拽协议，不是
Mac 的 Drag Drop Board 丢事件。

## 9. 命令分发与包结构（静态逆向）

### 命令分发器

`handleCommand:`（`0x100026f87`）按 commandID 分发：

| ID | 方法 |
|---|---|
| `0x10` | `handleDownloadMultipleFile:` |
| `0x37` | `handleChangeFileAttribute:` |
| `0x39` | `handleExtraXMLPacket:` |
| 其他 | `handleUploadFileData:` / `handleUploadMultipleFile:` / confirm / abort / zero-length |

`handleDownloadMultipleFile:`（`0x100027a08`）把命令加入下载队列，
发送 `ResponseResult`，然后调用 `startDownload`。

### DownloadMultipleFile 包

`initFromData:`（`0x100008db1`）解析：

```
u32 multiSessionID        // 按 remoteIsBigEndian 决定字节序
u16 multipleFilesCount
repeat count:
  u32 fileID
  u16 filePathLength      // 字节数
  u8[filePathLength]      // OTi Unicode（UTF-16LE）路径
```

`encodeData`（`0x100008b13`）按同样顺序写出，并在 `commandID == 0x10`
时追加额外字段。

### DownloadFileData（0xa3）

`DownloadFileData` 的 `init` 设置 `commandID = 0xa3`；
`maxDataLength` 返回 **0x800000（8 MB）**，说明单个数据命令最大 8 MB，
不是固定 64 KB。

抓到的 `0xa3` payload 头：

```
u32 session   = 03 25 0f cf  (BE, 0x03250fcf)
u32 fileID    = 00 00 00 01  (BE, 1)
u8[3]         = 00 00 00
data          = PK\x03\x04 ...（docx）
```

`0x10` 抓包头：

```
01 00
cf 0f 25 03   // 与 0xa3 的 session 字节序相反
6e 00         // 0x6e = 110，正好是 UTF-16 路径字节数
UTF-16LE path
```

它更像单文件动态变体，而不是完整的多文件 `DownloadMultipleFile`
（后者应带 `fileID + pathLength`）。

### 最终确认（逐字节对齐）

`0x10`（`DownloadMultipleFile`，小端）：

```
u8  0x10
u32 multiSessionID        LE
u16 multipleFilesCount    LE
repeat count:
  u32 fileID              LE
  u16 filePathLength      LE
  u8[filePathLength]      UTF-16LE path
```

抓包实例：

```
10 ce0f2503 0100 cf0f2503 6e00 2f00 2f00 5500 7300 ...
   session  count fileID   len  "//Users..."
```

`multiSessionID = 0x03250fce`，`fileID = 0x03250fcf`。

`0xa3`（`FileDataCommand`，大端）：

```
u8  0xa3
u32 sessionFileID         BE
u32 totalCount            BE
u32 currentCountIndex     BE   // 1 基
u32 dataLength            BE
u8[dataLength]            data
```

抓包实例：

```
a3 03250fcf 00000001 00000001 00002cc3 504b0304...
   session  total=1  index=1  len=11459  PK..
```

`dataLength = 0x2cc3 = 11459`，整个 docx 在一个 `0xa3` 帧里。

### 分块结论

- 单帧上限 `maxDataLength = 0x800000`（8 MB）；
- 大于 8 MB 时按 `totalCount` / `currentCountIndex` 分块，index 从 1 开始；
- 文件数据就在 SCSI `D9 2A` 的 64 KB OTi 帧缓冲里，**不是 IOUSBLib bulk pipe**；
- 之前只看到 219 字节，是 `hexline` 把日志截断到 256 字节，不是传输通道不同。
