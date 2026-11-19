# 键鼠共享（KM）真机排查记录：鼠标跨屏 + "跨过来鼠标飞快"

> 结论来自反汇编原版 `KMKeyMouse.dylib` / `GoBridgeDemon`（未签名，x86_64）、
> 本机 `ioreg` 读取到的桥接线 HID 描述符，以及用户 2026-11-16/17 的真机测试日志。
> 最后更新：2026-11-17

---

## 0. 现象（用户报告）

| # | 现象 |
|---|---|
| 1 | 只用鼠标，Mac→Windows 跨不过去，Windows→Mac 也跨不过去 |
| 2 | 用快捷键可以从 Windows 跨到 Mac，但跨过来之后鼠标 "DPI 极高、非常飘、无法控制" |

---

## 1. 硬件事实（本机实测，2026-11-17）

桥接线（`VID 0x0EA0 / PID 0x2213`，Product `Android+Mac`）不是"只有存储"，
它同时枚举出 **HID 鼠标 / HID 键盘**：

| Interface | Class | SubClass | Protocol | 用途 |
|---|---|---|---|---|
| 0 | 8 (Mass Storage) | 6 | 0x50 | vendor SCSI 通道（`IOCompactDiscServices`，LUN 1） |
| 1 | 3 (HID) | 1 | **2 (Mouse)** | 对端 HID 注入的落点 |
| 2 | 3 (HID) | 1 | **1 (Keyboard)** | 同上 |

HID 鼠标 **ReportDescriptor**（从 `ioreg` 直接读出）：

```
05 01 09 02 a1 01 09 01 a1 00 05 09 19 01 29 05 15 00 25 01
95 05 75 01 81 02 95 01 75 03 81 01 05 01 09 30 09 31 09 38
15 81 25 7f 75 08 95 03 81 06 c0 c0
```

即 **4 字节相对报告、无 report id**：

```
byte0 = buttons(5 bit) + padding(3 bit)
byte1 = X (int8, 相对)
byte2 = Y (int8, 相对)
byte3 = wheel (int8)
```

键盘是标准 8 字节 boot keyboard：`[modifiers, reserved, key1..key6]`。

**结论**：Mac 作为被控端时，鼠标是桥接线的硬件 HID 注入的，macOS 的指针加速曲线
会直接作用在这些报告上；Mac 作为控制端时，我们用 vendor CDB `D9 00 33 <12B>`
把同一格式的报告发给桥，桥再转发给对端。

---

## 2. `functionType` 的正确解读（原版 `GoBridgeDemon`）

`F0 00 00` 返回的 64 字节里 `buf[0x20]` 就是 functionType（本机 = **0x88**）。
原版 `-[SKMBridge getFunctionType]` 的实现只返回**一个布尔值**：

```c
uint8_t ft = buf[0x20];                       // 0x88
m_functionType = ((ft & 0x88) == 0x88) ? 1 : 0;   // 1 => "Using Relative"
if (ft & 0x01) { /* "Support multimedia keyboard" */ }
```

**⚠ 我们的 `SCSITaskTransport.usesHIDReportID` 之前把 `ft & 0x01` 当成
"HID report id 存在"** —— 那是"支持多媒体键盘"的标记，跟 report id 无关。
0x88 的低位是 0，所以之前"碰巧"发对了相对格式，但语义是错的，换固件就会出错。
现已改为 `hidMouseUsesRelativeReports = (ft & 0x88) == 0x88`。

此外原版相对模式发的报告是 **`[buttons, dx, dy, ±1]`**，其中的 ±1 是
"重定位方向步进"，并**不是**滚轮；同时原版会**阻尼大位移**
（`|d| > 20` 时折半，再夹到 ±128），见 `CKMEvent::SendMouseEvent`。
我们的实现原来直接夹到 ±127 不加阻尼，快速甩动时对端会过冲。
现已加入同样的阻尼（`USBLink.dampedRelativeDelta`）。

---

## 3. "跨过来鼠标飞快" 的根因（已修）

原版在切换为 **控制端** 时会把系统鼠标速度改成 `-1`（关闭加速），
切回时恢复原值：

```c
CKMEvent::SwitchToRemote(int dir) {
    [mouseInterface setMouseSpeed:-1.0 andTrackpadSpeed:-1.0];  // 写 com.apple.mouse.scaling
    ...
}
CKMEvent::SwitchFromRemote(int dir) {
    [mouseInterface restoreDefaultSpeed];                        // 写回用户原值
    ...
}
```

`MouseInterface` 就是 `defaults write -g com.apple.mouse.scaling <x>`。

**我们的 bug**：`oti_hid_tune_mouse(true, 1.0, …)` 会把这个桥接鼠标（只认
`VID=0x0EA0/PID=0x2213`、usage 1/2）的 IOKit 加速属性写成 **6144/6144**，
而 macOS 给本设备的默认值是：

| key | 默认值 | 我们原来写的 |
|---|---|---|
| `HIDPointerAcceleration` | **45056** | 6144 |
| `HIDMouseAcceleration` | **32768** | 6144 |

在这块桥接线上，**加速值越小 → 指针越快**。把默认值改成 6144 相当于把指针放到
约 5 倍速，正是用户反馈的"DPI 极高、非常飘、根本无法控制"。
而且 IOKit service 属性**在进程退出后仍然保留**，所以那次写得的值会一直毒害后续
测试（本机 2026-11-17 实测仍是 6144，已经用 `tools/hidrestore.c` 恢复）。

**修复**：

- `oti_hid_tune_mouse(enabled, speed, …)` 语义改成"相对 macOS 默认的指针速度倍率"：
  - `speed == 1.0`（默认）→ **完全不覆盖**，并把数值写回系统默认（自愈）；
  - `speed < 1.0` → 数值按 `默认值 / speed` 放大（更慢）；
  - `speed > 1.0` → 数值缩小（更快），有下限保护。
- 新增 `oti_hid_restore_mouse_defaults()`，在 **启动 / 断开 / 退出** 时都调用，
  保证不会再有历史脏值残留。
- 设置面板里这一项改名为 **Pointer speed**，1.00× 表示"跟随 macOS 默认"。

> 若将来遇到固件方向相反的情况，只需要把 `SCSITaskShim.c` 里
> `oti_hid_accel_for_speed()` 的除法改成乘法（有注释说明）。

---

## 4. 切屏（鼠标跨屏）协议流程

原版行为（反汇编 + 抓包日志双向确认）：

```
Mac(控制端) 鼠标顶到朝对端的屏幕边缘 2 次采样
   → Cmd_Notify_KM_Switch_To_Remote  (0x39 XML，含 Param_Move_Out_Info)
   → 之后才开始发 HID 相对报告            ("Start switching holding for HID delay...")

Mac(被控端) 收到 Cmd_Notify_KM_Switch_To_Remote
   → 解析 Param_Move_Out_X/Y/Direction，把光标 warp 到入点
   → 回 Cmd_Get_KM_Switch_Acknowlege (Param_Remote_Screen_Size: CapsLock / ScrollDirection)
   → m_bInRemoteControl = 1（被控）

Mac(被控端) 注入光标自己顶出边缘
   → Cmd_Force_Remote_To_Switch_Local (Param_Move_In_Info: X/Y/Direction)
   → m_bInRemoteControl = 0 且立刻转为控制端（不再多发一次 switch-to-remote）
```

**我们之前的 bug**：`endUSBSlave()` 只回到"本地"状态，于是下一次边缘采样又触发
`Cmd_Notify_KM_Switch_To_Remote`，两台机器来回抢控制权（用户日志里可见
`Cmd_Force_Remote_To_Switch_Local` 每秒好几条地刷）。现在：

- `endUSBSlave(..., becomeMaster: true)`：发完 force-switch-local 后**直接进入控制端**，
  和原版一致（`m_bInRemoteControl: 0` + master）；
- 切换后 2 秒内屏蔽边缘检测（原版 `Switching holding ... expired` 的等价物），
  并延迟 150 ms 才发第一个 HID 报告；
- 边缘判定从"3 个连续事件"改为"400 ms 窗口内 2 次外向采样"（原版是
  `secondcheckswitch` 二次确认），抖动不会再把跨屏吞掉；
- `Cmd_Notify_KM_Switch_To_Remote` 的 `Param_Move_Out_Info` 即使解析失败，
  也**必须进入被控态**（方向记为 0，回程边退回设置里的 "Other PC is on the"），
  否则 Mac 停在"本地"状态、Windows 已经是控制端，两边会互相抢；
  XML 解析现在会依次尝试 0/1/2 层实体转义。
- 新增 `KM edge:` 诊断日志：光标停在边缘但增量方向不对时会直接打出
  `at screen edge but delta … is not outward for peer=…`，
  最常见的原因是设置里"Other PC is on the"方向选反了。

---

## 5. 联机握手（顺带修掉）

Windows GO! Bridge 大约每 10 秒重发一次 `LoginCommand`（用户日志里可见），
说明它一直没看到完整握手。原版收到 `LoginCommand` 时会**每次都重新宣告**自己。
我们现在也是每次收到 `0x01` 都完整回复：

```
0xA1 ResponseResult(os=0x28)
0x01 LoginCommand(name)
0xAD DomainFolders
0xA4 DriveInfo
```

---

## 6. 真机复测步骤

1. `./build.sh && open build/KMLink.app`
2. 确认设置里 **Other PC is on the** 指向 Windows 实际所在的一侧。
3. **Pointer speed 先保持 1.00×**（macOS 默认）。跨过来之后如果嫌快，调到 0.8× 试。
4. 在 Windows 端用 GO! Bridge 把鼠标顶到朝 Mac 的边缘，观察 Mac 端日志：
   - 正常应出现 `USB moveOut: dir=… x=… y=…` 且光标被 warp 到入点；
   - 若出现 `KM edge: at screen edge but delta … is not outward`，就是方向设置反了。
5. 从 Mac 跨回 Windows：把鼠标顶到朝 Windows 的边缘，应看到
   `KM edge: edge crossing to remote: …` 和 `USB TX: Cmd_Notify_KM_Switch_To_Remote`。

排障工具：

```bash
# 看桥接鼠标当前的 HID 加速值（正常应是 45056 / 32768）
clang -target arm64-apple-macos13.0 -isysroot "$(xcrun --show-sdk-path)" \
  -framework IOKit -framework CoreFoundation -o /tmp/hidrestore tools/hidrestore.c
/tmp/hidrestore read

# 列出所有 HID service 及 OTi 鼠标属性
clang -target arm64-apple-macos13.0 -isysroot "$(xcrun --show-sdk-path)" \
  -framework IOKit -framework CoreFoundation -o /tmp/hidprobe tools/hidprobe.c
/tmp/hidprobe | grep -A8 "VID=3744"
```

---

## 7. 2026-11-17 第二轮真机日志分析：0x39 写失败 + Windows 侧不发 KM 命令

用户复测日志（15:18）关键三行：

```
[15:18:34] KM edge: edge crossing to remote: peer=left at 0,529 delta=-1,0
[15:18:35] USB switch-to-remote failed: write failed: code=2 status=2 sense=7000...000a0000...
[15:18:36] No switch ACK from Windows within 2s; restored Mac control
```

**结论 1：边缘检测已经正常**（方向、坐标、增量都对）。失败发生在把
`Cmd_Notify_KM_Switch_To_Remote` 写进桥接线的 64 KB 数据阶段。

**结论 2：写失败与帧内容无关。** `/tmp/kmlink-scsi.log` 统计
（整段历史 1047 次 `D9 2A`）：1025 次 rc=0，22 次 rc=2；失败签名恒为
`status=2 / sense=70 00 00 00 00 00 00 0a 00…`（NO SENSE）且耗时固定 ≈1.28 s，
而**同样的 1380 字节 switch 帧在 14:21:11 是成功的**；失败里也包含 9 字节的 0x01
帧和零块。原版 daemon 也出现过同样的 `status 2 / sense key 9`，说明这是固件/链路
的偶发拒绝，不是我们构造错了。

**结论 3：帧头格式与原文一致（已用原版抓包逐字节确认）。**
原版真实写出的 0x39 帧：

```
01000000 01000000 00000000 01000000 85010000 39 00000180 <ExtraXml...>
02000000 02000000 ...            # word0 == word1 == sequence
```

即 `0x00 = 0x04 = sequence`，`0x14 = type`，`0x15 = payloadLen-5 (BE)` —— 我们的
`OTIFrame.encoded()` 完全一致。（旧文档里"0x39 的 0x00 固定为 1"是误读，那次抓包的
sequence 恰好是 1。）同时确认原版也是 `len=65536` + 一个全零伴随块。

**所以本轮改动**：`SCSITaskTransport.send` 失败后重试 3 次（每次先抽干 RX、间隔
400 ms），switch ACK 等待放宽到 5 s；`ResponseResult(0xA1)` 的 TLV 长度字节补成
`0x0a`（Windows 端用这个长度定位 `OSVERSION` 块，我们原来写 0）。

**仍然存在的关键问题（需要 Windows 侧信息）**：
整段日志里我们**从未收到过任何 0x39 帧**（只有 0x01/0xA1/0xAD/0xA4 心跳），
而原版抓包里 Windows 会主动发 `Cmd_Notify_KM_Switch_To_Remote`；即使我们那帧写成功
（14:21:11）Windows 也没有回 `Cmd_Get_KM_Switch_Acknowlege`。
这说明 Windows 侧没有把本机当成"键鼠共享对端"。原版登录握手比我们多两帧：

| seq | type | 长度 | 说明 |
|---|---|---|---|
| 1 | 0xA1 | 44 | OSVERSION（已有） |
| 2 | 0xAD | 352 | 目录（已有） |
| 3 | 0xA4 | 693 | 卷（已有） |
| **4** | **0xA1** | **34** | **登录子命令 0x04（我们没有）** |
| **5** | **0xA2** | **563** | **屏幕/版本二进制信息（我们没有）** |

`0xA2` 很可能就是"告诉对端我的屏幕尺寸/边缘位置"的帧，缺了它 Windows 无法做
鼠标越界判断（这也解释了为什么快捷键能用、鼠标越界不能用：快捷键不需要对端几何）。
下一步需要抓一次原版 App 的 TX 帧（`tools/iokitlog.c` / `streamlog_oti.m`）来复刻
这两帧的字节。

---

## 8. 第三轮（15:38 日志）：switch XML 与原版逐字段对齐 + 重发

用户日志：`sense=700009000000000a…8500`（sense key 0x09 = ABORTED COMMAND、
ASC 0x85）——和原版 daemon 抓到的 `task status 2 / sense key 9 / 0x85` 完全一致，
连原版自己也会遇到，它会重发。

对照早先抓到的原版 `Cmd_Notify_KM_Switch_To_Remote`，
我们的 XML 少了两处，已补：

1. `<Param_Point_Event_Data>`：32 字节 hex，原版必带的"点事件"结构
   ```
   00000000 000F0000 70080000 00000000 00000000 00000000 03000000 9A030000
   u32[0]=0  u32[1]=屏宽  u32[2]=屏高  u32[3..5]=0  u32[6]=3  u32[7]=Move_Out_Y
   ```
2. 末尾的 `<Param_Clipboard_Info_2></Param_Clipboard_Info_2>`。

同时把 `<Param_KM_Setting_Info>` 收敛成原版那三个子元素、`<Param_Other_PC_Position_Option>`
与 direction 一致。Windows 侧对缺字段很可能直接丢弃整条命令（这能解释"帧写成功
但对方毫无反应"）。

另外 `USBLink` 在发出 switch 命令 600 ms 内没收到 `Cmd_Get_KM_Switch_Acknowlege`
就自动重发一次（原版同样会重发），`SCSITaskTransport.send` 仍保留 3 次写重试。

## 9. 抓原版 A1(0x04) / A2 受阻：原版需要"辅助功能"授权

按 `docs/FILE-TRANSFER-RE.md §5` 的方式注入 `build/iokitlog.dylib` 启动原版：

- 直接跑 `GoBridgeDemon -LaunchByShell`：dylib 能加载，但 daemon 一行 SCSI 都不发；
- 跑 `MacKMLink.app`：daemon 打印 `Create gesture event tap failed!!`，
  随后 `daemonIsAlive: hasEnabledAccessibility: 0` → `Demon terminated!!!`，
  整个 App 自行退出。

**结论**：没有给原版 MacKMLink 授予"辅助功能"，它的 daemon 不会进入真正的工作状态，
也就抓不到登录帧。要继续复刻 `0xA1(34B, cmd 0x04)` 和 `0xA2(563B, 屏幕/版本信息)`，
需要先手工在 系统设置 → 隐私与安全性 → 辅助功能 里授权
`~/Library/MacKMLinkFull/MacKMLink.app`，然后再注入抓包。

---

## 10. 0x39 写失败的真因：写出瞬间的背景轮询（已修，工具验证 5/5）

用 `tools/xmlframe.c`（直接走 `Sources/SCSITaskShim.c`，不带 App 的轮询线程）做对照实验：

| 场景 | 结果 |
|---|---|
| 每次写前不排空 RX，连续写 8 帧 | 2/8 成功，失败耗时恒 ≈1.28 s、`status=2 / NO SENSE` |
| 每次写前排空 RX（`poll tx=0` 直到非 0x05）后写 | **8/8 成功** |
| 同上，但负载换成 1245 B（与真实 switch 帧同量级） | **8/8 成功** |

而 App 里同样的帧几乎必失败 —— 差别只在 **App 每 50 ms 的 `D8 00 03` 轮询**：
设备在数据阶段被背景轮询打断就会 abort。

**修复**：

1. `SCSITaskTransport.send`：每次尝试前先排空 RX（最多 8 轮）、失败重试 4 次、
   间隔 200 ms；
2. `LinkNode.setSwitchInFlight(true)`：切屏命令在途时把轮询间隔从 50 ms 降到
   500 ms（仍会读 ACK），收到 ACK 或超时后恢复；
3. `USBLink`：switch 命令写失败也照样排进重发队列（最多 4 次），并 600 ms 后自动重发。

验证工具（无需真鼠标）：

```
./build/KMLink.app/Contents/MacOS/KMLink --switchtest
→ SWITCHTEST: frame 1..5 OK (1233 B payload, 28–83 ms)  5/5 accepted
```

仍未确定的一点：Windows 收到这帧后**是否执行**（我们的日志里始终没有
`Cmd_Get_KM_Switch_Acknowlege` 回帧）。如果真机测试仍不能穿屏，就需要抓原版的
`0xA1(34B, cmd 0x04)` + `0xA2(563B 屏幕信息)` 两帧（见 §9，需先给原版授权辅助功能）。

---

## 11. 决定性结论：HID 注入不需要对端配合（2026-11-17 真机确认）

用户实测 `--hidtest`（30 个 `D9 00 33` 相对报告，无任何 KM 握手）：
**Windows 上的指针移动了**。

由此得出：

1. 桥接线的 HID 注入是**硬件转发**，不依赖 Windows 端 GO! Bridge 的 KM 状态；
2. 所以 `Cmd_Notify_KM_Switch_To_Remote` 的 ACK **不能**作为接管的先决条件
   （Windows 实际上从不回这个 ACK）；
3. 跨屏 Mac→Windows 所需的一切只有：把 switch 命令尽可能发出去（让对端别抢鼠标）
   + 持续注入 HID。

据此改动：

- `UI.armUSBSwitchAckTimer`：5 s 没 ACK 只写日志，**不再放弃控制**；
- `SCSITaskTransport.sendHID`：加 RX 排空 + 3 次重试（原来无任何保护，静默丢包）；
- `KMEngine`：控制端期间把本机光标**钉在屏幕中心**（`localPinPoint`，
  每次转发后 `CGWarpMouseCursorPosition`），否则 macOS 会把光标也一起移动，
  出现"两边鼠标都在动"。原版用"重发保存的 warp 事件"达到同样效果。
- 回本机：⌃⌥S（`kVK_ANSI_S` + control + option），会 `releaseAllHID()` 并发送
  `Cmd_Notify_KM_Switch_To_Local`。

尚未解决：Windows→Mac 的鼠标越界（需要 Windows 知道本机屏幕几何，
即 §9 的 `0xA1(0x04)`+`0xA2`）。

---

## 12. 最终可用方案（2026-11-17 17:48 真机验证通过）

用户实测通过。日志证据（`/tmp/kmlink-runtime.log`）：

```
[17:48:07] KM edge: edge crossing to remote: peer=left at 0,444 delta=-7,1
[17:48:12] No switch ACK from Windows; continuing with direct HID injection ...
[17:48:25] KM edge: hotkey ctrl+opt+S handled inside the tap
[17:48:30] KM edge: edge crossing to remote: peer=left at 0,478 delta=-1,0
[17:48:35] KM edge: hotkey ctrl+opt+S handled inside the tap
```

Mac → Windows 鼠标跨屏的完整链路（不依赖 Windows 端配合）：

1. 边缘判定（`edgeIsOutward` + 2 次命中/400 ms）→ `Cmd_Notify_KM_Switch_To_Remote`
   发出去（尽力而为，失败重发 4 次）；
2. **不等 ACK**，直接进入控制态，开始用 `D9 00 33` 注入 12 字节相对 HID 报告；
3. 每次转发后 `CGWarpMouseCursorPosition` 把本机光标钉在主屏中心
   （否则 macOS 会同时移动本机光标 = "两边都在动"）；
4. ⌃⌥S 在 **event tap 内部**识别（`keyCode==1 + control + option`）→
   `releaseAllHID()` + `Cmd_Notify_KM_Switch_To_Local` + 光标回进入边。

关键前提（排障必读）：

| 现象 | 原因 | 处理 |
|---|---|---|
| 写 64 KB 帧 `status=2 / NO SENSE`、耗时 1.28 s | 写的时候有 RX 待读 | 写前排空 RX（`poll tx=0` 直到非 0x05）|
| 同上但 `sense key 9 / ASC 0x85`、`0x39` 必失败 | 桥在写数据阶段被 50 ms 轮询打断 | 切屏命令在途时轮询降到 500 ms |
| poll 状态 `0x01`、所有写被拒 | **Windows 端 GO! Bridge 离线** | Windows 上重启 GO! Bridge；Mac 侧保持连接并等对端 |
| 桥接鼠标指针"飞快/飘" | `HIDPointerAcceleration/HIDMouseAcceleration` 被改小 | `tools/hidrestore` 或 App 自动恢复 45056/32768 |
| 跨过去后 Windows 指针不动 | 对端从不回 ACK，旧逻辑 5 s 放弃 | 已改为继续注入 |

仍未实现：**Windows → Mac 的鼠标越界**（必须由 Windows 发起；它需要知道本机屏幕
几何，即原版登录握手的 `0xA1(34B, cmd 0x04)` + `0xA2(563B)`，见 §9）。
当前该方向仍用快捷键（用户已验证可用）。

---

## 13. 收尾（2026-11-17 18:00）

1. **控制端光标停在出屏的那条边**（不再跳到屏幕中央）
   `KMEngine.pinTargetPoint(at:direction:)`：direction 1（对端在左）钉在 `minX+2`，
   2（对端在右）钉在 `maxX-2`，y 沿用离开时的位置。
2. **对端从相反的边进入**
   Windows 从不回 ACK、也不会自己 warp 指针，所以用相对报告"顶"过去：
   `USBLink.slamPointerToEntryEdge(direction:)` 在切屏后连发 80 个 ±127 的报告
   （出左边界 → 对端右边界；出右边界 → 对端左边界）。
   测试可用 `pointerPrePositionEnabled = false` 关闭。
3. **控制端临时关闭本机加速**
   `Sources/MouseScaling.swift`：控制态开始 `com.apple.mouse.scaling = -1`，
   结束恢复（原版 `MouseInterface` 行为）；原值存 `UserDefaults.SavedMouseScaling`，
   每次启动 `restoreIfNeeded()` 自愈（防止崩溃后加速一直是 -1）。
4. **补齐登录握手的后两帧**
   - `0xA1` **cmd=0x04**（34 字节，与 Windows 自己发的 34 字节 A1 同布局）
   - `Cmd_Post_Remote_Screen_Info`（本机 1512x982）
   目的是让 Windows 知道本机屏幕几何，从而可能自行做"鼠标从我这边越界到 Mac"的判定。
   （原版用的是 563 字节二进制 `0xA2`，其精确布局仍未拿到；XML 形式携带同样的两个参数。）

---

## 14. 关键遗漏：`Cmd_Post_Remote_KM_Setting_Info`（2026-11-17 18:40 补上）

从 `GoBridgeDemon` 反汇编里挖出这个命令的完整构造（builder 只用
`stringWithFormat:@"%d"` 填三个值）：

```
<OTIMSG>
  <NP_Cmd>Cmd_Post_Remote_KM_Setting_Info</NP_Cmd>
  <NP_Up_Notice_NamePipe_Name>\\.\pipe\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>
  <Param_Move_Out_Direction>1|2</Param_Move_Out_Direction>
  <Param_Move_Out_KM_Switch_Option>3</Param_Move_Out_KM_Switch_Option>
  <Param_Move_Out_Use_Hotkey_Switch_Only>0</Param_Move_Out_Use_Hotkey_Switch_Only>
</OTIMSG>
```

我们此前从未发过它 —— **对端因此不知道两台机器的相对位置**，也就无法判断
"鼠标是否从自己的边界朝 Mac 那一侧越出"。登录握手现在发三帧：

1. `0xA1 cmd=0x04`（34 B，与原版第 4 帧一致）
2. `Cmd_Post_Remote_Screen_Info`（本机 1512x982）
3. `Cmd_Post_Remote_KM_Setting_Info`（dir=1 表示对端在左，option=3）

## 15. 原版抓包仍被辅助功能挡住（授权对象是 GoBridgeDemon.app）

按 `FILE-TRANSFER-RE.md §5` 注入后运行原版，日志反复出现：

```
GoBridgeDemon[32845] Create gesture event tap failed!!
MacKMLink[82313] daemonIsAlive: ... { enableAccessibility = 0; }
```

即**辅助功能里被信任的必须是**
`~/Library/MacKMLinkFull/MacKMLink.app/Contents/PlugIns/GoBridgeDemon.app`，
只授权外壳 `MacKMLink.app` 不够。授权后 `enableAccessibility` 才会变成 1，
daemon 才会打开 SCSI 通道，届时可以抓到 `0xA2`（563 B）的完整字节。

---

## 16. 2026-11-18 08:59 抓包结论：`0xA2` 仍被 TCC 挡住

重插桥接线后卷已就绪（`/Volumes/MacKMLINK`、`NO NAME`），`--usbprobe`
`open + handshake OK`、`status 0x07`、`A1 login frame TX OK`，说明设备与对端都正常。

但原版 App 仍然起不来守护进程：

```
== AX / daemon ==
  21 enableAccessibility = 0      # 50 秒内重启 daemon 21 次
 21 gesture event tap failed
== SCSITask calls ==
0                                # 一次 SCSITask 调用都没有
```

即：**辅助功能必须勾选的是
`~/Library/MacKMLinkFull/MacKMLink.app/Contents/PlugIns/GoBridgeDemon.app`**
（列表里显示为 `GoBridgeDemon`），勾错了外壳 `MacKMLink.app` 不生效。

另外注意：**原版 App 靠挂载卷里的 `autorun.inf` 认设备**，而我们的
`--usbprobe` / KMLink 一旦打开 SCSITask 独占设备，光盘卷就会从系统消失到下
次重插。所以抓包顺序必须是：**重插 → 卷出现 → 立刻跑原版（不要先跑任何我们的工具）**。

已提供一键脚本（内部会检查卷是否就绪）：

```
./tools/capture_login.sh 50
```

授权到位后它会打印 `0xA1(34B)` / `0xA2(563B)` 的完整十六进制，
届时把 A2 补进 `OTISession` 即可。

## 17. 已核对：我们的 0xA1 与 Windows 完全一致（排除错位说）

Windows 真实 34 字节 A1：

```
[0]=a1 [1]=01 [2]=00 [3..6]=07 07 07 07
[19]=03 [20]=0a [21..23]=00 "OSVERSION"@[24..32] 版本@[33]
```

我们的编码器逐字节相同（只差 [3..6] 的版本字样，原版 Mac 抓包里那里是全 0）。
所以"登录帧错位导致 Windows 灰掉边缘选项"的假设**不成立**，剩下的差异就是
`0xA2`（563 B）这一帧。

---

## 18. 2026-11-18 双向跨屏打通（登录帧字节级修正 + 坐标缩放）

### 18.1 真正的根因：`0xA1` 的 TLV 整体早了一个字节

原版守护进程与 Windows 双方的真实负载（payload 从帧偏移 `0x14` 开始）：

```
Mac   : a1 01 00 | 00×17 | 03 | 00 00 00 00 | "OSVERSION"@25 | 10 00 00 00 | 值
Windows: a1 01 00 | 07 07 07 07 | 00×13 | 03 | 0a | 00 00 00 | "OSVERSION"@25 | 07
```

我们原来写成 `03`@19 / 长度@20 / 标签@24 / 值@33 —— **整体早 1 字节**，
Windows 因此完全找不到 `OSVERSION` 块。后果非常隐蔽：链路仍然通（它照常回
`ResponseResult result=0`），但 Windows 把对端识别成"裸桥（GO Bridge）"而不是
"Mac KMLink"，于是把 **「使用鼠标光标移出屏幕边界」整组灰掉**。

修正后 Windows 弹起的是 **Mac KMLink**，边缘切换选项可用。

### 18.2 `LoginCommand`（0x01）必须用原版形状

```
原版 Mac : 01 10 00 00 <名字长度> <主机名>
Windows  : 01 07 a8 03 06 "WINPC1"      （os + codePage + 名字）
我们原来 : 01 28 00 00 <长度> <名字>    ✗ 把 0x28 当 OS 版本
```

改成 `01 10 00 00 …` 后 Windows 才正确识别对端产品。

### 18.3 `0xA2` 只有 11 字节

```
a2 00 00 00 00 00 15 c4 df 90 00
```

文档里"563 字节屏幕/版本信息"的说法是错的，它装不下屏幕几何 —— 边缘选项的灰度
与它无关（真正原因是 18.1）。

### 18.4 坐标：两个方向都必须换算到对端像素空间

- `Cmd_Force_Remote_To_Switch_Local` 只有 `Param_Move_In_X/Y`（无 w/h），对端
  **当作自己的像素**使用 → 必须 `y * peerH / localH`；
- 对端分辨率从 `moveOut` 的 `w/h` 学（`Cmd_Post_Remote_Screen_Info` 它并不总发）。
  修之前 `remoteScreenHeight` 停在默认 1080，而 Windows 是 2160，等于只按一半
  比例发，所以每次落点都偏高。
- 交回控制权时**不要**把本地光标钉到边缘中点，要保留当时的高度（否则跨过去的
  瞬间 Mac 光标会向上跳）。

### 18.5 从机模式的指针不可信（回切判定的根本困难）

Windows 作为主机时会用**绝对定位**摆放我们的光标：

```
slave probe: p=664,322 → 19,556 → 1350,79 → 275,453   （每帧 delta 只有 ±2…12）
slave probe: d=-441,-168                               （瞬移产生的伪位移）
```

所以回切判定必须：过滤 |>100px| 的瞬移样本、以**真实光标**判定"在边缘"、
要求贴边 ≥150ms、累计外推 ≥30px，并且"先在屏幕内真实移动过 200px"才武装。
`⌃⌥S` 始终是 100% 可靠的替代路径。

### 18.6 复现/验证要点

- 抓原版登录帧：`./tools/capture_login.sh 50`（先退出 KMLink、重插桥接线）；
- 说明：原版守护进程必须有辅助功能授权，macOS 26 里这条权限页叫
  **Device Control and Data Access**；
- 我们自己的 SCSITask 独占会让光盘卷消失到下次重插，所以抓包顺序不能颠倒。

---

## 19. 2026-11-18 高度连续性（跨屏位置语义定稿）

用户确认的语义：**接收方**的光标被重置为**发送方离开那一刻的位置**（按屏幕高度等比）：

| 方向 | 现在 | 实现 |
|---|---|---|
| Mac → Windows | Windows 指针 = Mac 离开高度 × `H_win/H_mac` | `endUSBSlave` 用真实光标坐标（`event.location`），`sendForceRemoteSwitchLocal` 负责缩放 |
| Windows → Mac | Mac 光标 = Windows 离开高度 × `H_mac/H_win` | `entryPoint(from:)` 按 `remoteWidth/Height` 等比 |

要点：

1. **不能用虚拟光标**做交接值。虚拟光标的 Y 初始值来自"对端上次进入的高度"，
   交回控制权时若用它，本地光标会跳回那个陈旧位置（表现为"跨过去的瞬间 Mac
   光标瞬移到 Windows 上次进来的坐标"）。
2. 交回控制权时钉本地光标只改 X（贴出屏边），**Y 保持用户当时的位置**。
3. 出屏判据与位置判定都容易受对端绝对定位干扰，详见 §18.5。

## 20. 收尾修复

`MouseScaling.restore()` 用 `object(forKey:) as? Double` 判断保存值，若该值以整数
类型存入则转换失败并静默返回，导致**系统鼠标加速一直停在 -1**。已改为
`double(forKey:)`，并在启动时加兜底：若发现 `com.apple.mouse.scaling == -1` 且
本地无保存值，直接写回 `1.0`。
