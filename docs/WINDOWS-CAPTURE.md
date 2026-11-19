# Windows 侧 USB 抓包步骤（USBPcap + Wireshark）

目标：抓到 Windows 原版 GO! Bridge 与桥接线之间的 USB 流量，重点看
Bulk-Only Transport 的 `D9 2A`（写数据）和 `D9 28`（读数据）里承载的
uPipe XML 帧。

## 1. 安装

1. 安装 **Wireshark 4.x**，安装向导里勾选 **Install USBPcap**。
2. 安装完成后重启 Windows（USBPcap 需要替换 USB 驱动栈）。
3. 确认开始菜单里有 `USBPcapCMD`，Wireshark 欢迎页能看到 `USBPcap1/2/...`。

## 2. 抓包前准备

- Mac 端保持 `MacKMLink` 运行并与 Windows 端连接。
- Windows 端保持原版 GO! Bridge 运行。
- 不要复制真实密码/隐私内容；用测试文本，例如 `KMLINK-TEST-123`。
- 关闭其他会占用 USB 设备的工具（虚拟机 USB 重定向、手机助手等）。

## 3. 选择接口

桥接线在 Windows 的某个 USB 根 hub 下。最稳妥的做法：

1. 打开 Wireshark，在欢迎页 **按住 Ctrl 多选所有 `USBPcap` 接口**。
2. 点 Start，开始抓包。
3. 在过滤栏输入：

```
usb.idVendor == 0x0ea0
```

如果抓不到，改用：

```
usb.idProduct == 0x2213 || usb.product == "Android+Mac"
```

或先不加过滤，在设备管理器里确认桥接线所在的 hub，再只选对应的
`USBPcapN`。

## 4. 触发要抓的行为

按顺序做，每步之间停 1–2 秒，方便按时间定位：

1. 启动/重启 Windows GO! Bridge（抓初始化序列）。
2. Mac 复制 `KMLINK-TEST-123` → Windows 粘贴。
3. Windows 复制 `WIN-TEST-456` → Mac 粘贴。
4. Mac 拖一个小文件到 Windows。
5. Mac 鼠标移出边缘，移动几下，再按 ⌃⌥S 返回。
6. 停止抓包。

## 5. 过滤与导出

在 Wireshark 里先过滤掉无关流量：

```
usb.idVendor == 0x0ea0 && usb.transfer_type == 0x03
```

`0x03` 是 Bulk 传输，桥接线的 SCSI 数据和 uPipe 帧都在这里。

然后导出两份：

1. **File → Save As** → `kmlink-usb.pcapng`（原始包，保留结构）。
2. **File → Export Packet Dissections → As Plain Text**
   → 勾选 **Packet details: All expanded**、**Packet bytes**
   → 保存为 `kmlink-usb.txt`。

如果 pcapng 太大，可以只导出过滤后的包（File → Export Specified Packets
→ Displayed）。

## 6. 需要提供的信息

- `kmlink-usb.pcapng` 和 `kmlink-usb.txt`
- Windows 版本（Win10/Win11）
- 抓包时 Mac/Windows 是否已连接
- 每一步的大致时间点（例如“10s 时复制了 KMLINK-TEST-123”）
- 如果知道，桥接线在 Windows 设备管理器里的 VID/PID

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| 看不到 USBPcap 接口 | 重装 Wireshark 并勾选 USBPcap，重启 |
| 抓不到任何包 | 换一个 `USBPcapN`；确认选的是桥接线所在的根 hub |
| 抓到但全是中断包 | 加 `usb.transfer_type == 0x03` 过滤 Bulk |
| 设备在抓包时断开 | USBPcap 安装后未重启，或 hub 供电不足 |
| 文件太大 | 只保留 `usb.idVendor == 0x0ea0` 的包再导出 |

## 8. 安全提醒

pcap 会包含剪贴板内容、文件名，甚至文件正文。请只使用测试数据；
如果不方便提供完整包，可以先只抓“初始化 + 一次测试文本复制”这一段。
