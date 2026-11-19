# 原版一键卸载脚本使用文档

> 脚本：[`tools/uninstall-original.sh`](../tools/uninstall-original.sh)
> 适用：macOS 13+（Apple Silicon / Intel 均可），无需 root，无第三方依赖
> 最后更新：2026-11-19

一句话：**把「原版 MacKMLink（OTi GO! Bridge 系）在 mac 上留下的 4 处东西」用一条命令清干净，默认先备份。**

---

## 1. 它解决什么问题

原版是 x86_64 的 USB 桥接方案（`/Applications/MacKMLink.app` 外壳 +
`~/Library/MacKMLinkFull/` 载荷），运行时会常驻 `GoBridgeDemon`，通过私有 SCSI 命令
独占桥接线对应的 USB 设备/LUN。做复刻版联调时，两边会抢设备，手工卸载又要处理
「应用 / 载荷 / 偏好 / 隐私授权」四处，容易漏。

脚本把这些收拢成一次性、可预演、可备份的流程，并且只删除白名单内的内容。

## 2. 原版在系统里留下的东西

| 位置 | 内容 | 由谁处理 |
|---|---|---|
| `/Applications/MacKMLink.app` | 安装外壳 `com.oti.MacKMLinkShell` v1.0.1325.52，内含 `Contents/Resources/MacKMLinkFull.tgz` | 脚本删除 |
| `~/Library/MacKMLinkFull/` | 外壳解包出的载荷：`MacKMLink.app`（`com.oti.MacKMLinkWithGOBridge` v2.0.0.7）、`Contents/PlugIns/GoBridgeDemon.app`（`com.oti.GoBridgeDemon`）、`MacKMLinkShell.app` | 脚本删除 |
| `~/Library/Preferences/com.oti.*.plist` | `com.oti.MacKMLinkWithGOBridge`、`com.oti.GoBridgeDemon`（以及可能存在的 `com.oti.MacKMLinkShell`） | 脚本 `defaults delete` |
| 系统设置 › 隐私与安全性 › 辅助功能 / 输入监控 | TCC 授权（`CGEventTap` 需要辅助功能权限） | 脚本 `tccutil reset`，GUI 可兜底 |

两个容易忽略的点：

1. **外壳和载荷是两处**。只删 `~/Library/MacKMLinkFull` 而 `/Applications` 外壳还在，
   下次双击外壳会把载荷重新解包出来。彻底卸载必须两处都清。
2. **`/Volumes/MacKMLINK` 不是安装内容**，它是桥接线自带的虚拟光盘卷（读卡器/CD-ROM 形态）。
   脚本不会动它；想让它消失请拔掉桥接线的 Mac 端，想重装时重新插上即可。

原版**没有** launchd 项、特权 helper（`/Library/PrivilegedHelperTools`）、pkg 收据或
DriverKit 系统扩展，所以不需要跑系统级卸载器。

## 3. 快速开始

```bash
# 在仓库根目录执行
# 1) 预演：只打印计划，不动任何文件
./tools/uninstall-original.sh --dry-run

# 2) 确认计划无误后真卸载：交互输入 yes，自动备份到 ~/Desktop
./tools/uninstall-original.sh
```

非交互（例如写进自动化）用：

```bash
./tools/uninstall-original.sh --yes
```

脚本文件已带可执行位（`755`）；若从其它渠道拷贝后丢了权限：

```bash
chmod +x tools/uninstall-original.sh
```

## 4. 参数说明

| 参数 | 作用 |
|---|---|
| *(无参数)* | 交互模式：显示计划 → 要求输入 `yes` → 备份 → 卸载 |
| `--dry-run` / `-n` | 只探测并打印计划与将执行的命令，**不做任何修改**，不需要确认 |
| `--yes` / `-y` | 跳过 `yes` 确认（仍然会备份） |
| `--no-backup` | 不备份，直接卸载 |
| `--backup-dir DIR` | 备份目录，默认 `~/Desktop` |
| `--keep-installer` | 保留 `/Applications/MacKMLink.app` 外壳，只清载荷、偏好、授权 |
| `-h` / `--help` | 打印脚本头部说明 |

> `--keep-installer` 的语义是「保留安装器以便随时重装 / 继续抓包」。
> 注意保留外壳后，双击它仍会重新解包出载荷；想彻底阻止重装就不要用它。

退出码：

| 码 | 含义 |
|---|---|
| `0` | 成功；或本来就没装（幂等，重复运行安全） |
| `1` | 用户取消、备份失败中止，或有项目未清理干净（结尾有 ✘ 提示） |
| `2` | 用法错误、未知参数、以 root 运行、`HOME` 异常、无法交互确认 |

## 5. 交互流程与输出示例

### 5.1 预演（`--dry-run`）

```text
==> 卸载计划
  将执行：停止进程 → 备份 → 删除安装内容 → 清偏好 → 重置授权 → 校验

  安装外壳：删除 /Applications/MacKMLink.app（1.4M）
  解包载荷：删除 /Users/<username>/Library/MacKMLinkFull（4.4M）
  偏好设置：删除 com.oti.MacKMLinkWithGOBridge com.oti.GoBridgeDemon com.oti.MacKMLinkShell
  运行进程：无
  TCC 授权：重置 Accessibility / ListenEvent（预演）
  备份目录：/Users/<username>/Desktop（tar.gz）

==> 预演（--dry-run，未做任何修改）
  将执行：tar -czf "/Users/<username>/Desktop/MacKMLink-original-<时间戳>.tgz" ...
  将执行：lsregister -u "/Applications/MacKMLink.app"
  ...
  将执行：rm -rf -- "/Applications/MacKMLink.app"
  将执行：rm -rf -- "/Users/<username>/Library/MacKMLinkFull"
  将执行：defaults delete "com.oti.MacKMLinkWithGOBridge" 2>/dev/null（若存在）
  将执行：tccutil reset Accessibility "com.oti.MacKMLinkWithGOBridge" + ListenEvent
  ...

  ✔ 预演结束，未改动任何文件。去掉 --dry-run 即为实际执行。
```

> 尺寸、路径条数随机器状态变化；「运行进程：无」是当前状态探测结果。

### 5.2 真卸载（示意）

```text
确认卸载原版 MacKMLink？输入 yes 继续，其他任意键取消：yes

==> 备份
  ✔ 已备份到 /Users/<username>/Desktop/MacKMLink-original-20261119-110230.tgz（3.5M）
  恢复：sudo tar -xzf "/Users/<username>/Desktop/MacKMLink-original-20261119-110230.tgz" -C /

==> 终止原版进程
  ✔ 没有在运行的原版进程

==> 反注册 LaunchServices
  ✔ 已反注册 /Applications/MacKMLink.app
  ...

==> 删除安装内容
  ✔ 已删除 /Applications/MacKMLink.app
  ✔ 已删除 /Users/<username>/Library/MacKMLinkFull

==> 清理偏好设置
  ✔ 已删除偏好域 com.oti.MacKMLinkWithGOBridge
  ✔ 已删除偏好域 com.oti.GoBridgeDemon

==> 重置隐私授权（辅助功能 / 输入监控）
  ✔ 已对 3 个 bundle id 执行 tccutil reset（无记录时静默跳过）

==> 校验
  ✔ 安装内容、偏好、进程均已清理干净

卸载完成。
别忘了：系统设置 › 通用 › 登录项与扩展 里若还有 MacKMLink 项，点「−」移除。
```

确认环节是**严格匹配**：只有输入完整小写 `yes` 才继续，直接回车或其它输入都会取消
（退出码 `1`，不会做任何修改）。在没有终端的环境（CI、管道）里不加 `--yes` 会直接报错退出。

## 6. 脚本内部做了什么

执行顺序（与脚本一致）：

1. **现状探测**：检查两处安装路径、3 个偏好域、`~/Library` 下的 `com.oti.*` 零散残留、
   运行中的进程；顺带用 `du` 统计大小。什么都没有时直接提示「无需卸载」（幂等）。
2. **备份**：`tar.gz` 到 `~/Desktop/MacKMLink-original-<YYYYmmdd-HHMMSS>.tgz`，
   包含外壳（除非 `--keep-installer`）、载荷、偏好 plist、零散残留。
   备份失败立即中止，**不会进入删除阶段**。
3. **终止进程**：按模式
   `MacKMLink.app/Contents/MacOS* | MacKMLinkShell.app/Contents/MacOS* | GoBridgeDemon`
   先 `TERM`，5 秒不退再 `KILL`。
4. **LaunchServices 反注册**：对存在的 bundle 路径执行 `lsregister -u`，避免删完后
   Spotlight / 服务里留下幽灵记录。
5. **删除安装内容**：`rm -rf` 两处路径；失败会提示需要 `sudo rm -rf` 手工收尾并置退出码。
6. **清理偏好与残留**：
   - `defaults delete com.oti.MacKMLinkWithGOBridge / com.oti.GoBridgeDemon / com.oti.MacKMLinkShell`
   - `~/Library/{Saved Application State,Caches,Application Support,Logs,Containers,HTTPStorages,WebKit,LaunchAgents}` 下精确匹配 `com.oti.*` 的残留
7. **重置 TCC**：对 3 个 bundle id 分别 `tccutil reset Accessibility` 与
   `tccutil reset ListenEvent`（不存在记录时静默跳过）。
8. **校验**：复查两处路径、偏好文件、进程；有遗留则逐项 ✘ 并返回 `1`，最后提示
   `/Volumes/MacKMLINK`（若仍挂载）与登录项的人工检查点。

对应的手动等价命令（想自己一步步做时）：

```bash
pkill -f 'MacKMLink\.app/Contents/MacOS|MacKMLinkShell\.app/Contents/MacOS|GoBridgeDemon'

LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -u "/Applications/MacKMLink.app"
$LSR -u "$HOME/Library/MacKMLinkFull/MacKMLink.app"

rm -rf -- /Applications/MacKMLink.app "$HOME/Library/MacKMLinkFull"
defaults delete com.oti.MacKMLinkWithGOBridge 2>/dev/null
defaults delete com.oti.GoBridgeDemon 2>/dev/null
tccutil reset Accessibility com.oti.MacKMLinkWithGOBridge
tccutil reset ListenEvent   com.oti.MacKMLinkWithGOBridge
tccutil reset Accessibility com.oti.GoBridgeDemon
tccutil reset ListenEvent   com.oti.GoBridgeDemon
```

## 7. 卸载后检查清单

- [ ] 系统设置 › 隐私与安全性 › **辅助功能**：还有灰掉的 `MacKMLink` / `GoBridgeDemon` 就点「−」
- [ ] 系统设置 › 隐私与安全性 › **输入监控**：同上（如果出现过条目）
- [ ] 系统设置 › 通用 › **登录项与扩展**：若残留 `MacKMLink` 项（带感叹号）点「−」
- [ ] **Dock**：手动移除固定图标（脚本不碰 Dock）
- [ ] **通知中心**：历史通知不会立即消失，可在 系统设置 › 通知 里清理；偏好删掉后不会再产生
- [ ] `/Volumes/MacKMLINK` 仍在 → 拔掉桥接线 Mac 端（不属于安装内容）
- [ ] 菜单栏/图标刷新：注销或重启一次最稳

## 8. 备份与恢复

- 文件名：`MacKMLink-original-<YYYYmmdd-HHMMSS>.tgz`，默认在 `~/Desktop`
- 大小：约 3.5 MB（未压缩合计约 5.8 MB：外壳 1.4 MB + 载荷 4.4 MB，另含偏好；实机实测 3.5 MB）
- 内容：归档里是**去掉前导 `/` 的绝对路径**（如 `Applications/MacKMLink.app`、
  `Users/<username>/Library/MacKMLinkFull/...`），便于原位恢复
- 恢复：

```bash
sudo tar -xzf ~/Desktop/MacKMLink-original-20261119-110230.tgz -C /
```

恢复后如需再次运行原版，注意它仍是 x86_64，Apple Silicon 上依赖 Rosetta。

## 9. 常见问题（FAQ）

**Q1：我只是不想让它和新版抢 USB，需要卸载吗？**
不需要。原版没有登录自启，`pkill -f GoBridgeDemon`（必要时连 `MacKMLink` 一起）就够了，
退出后不会被自动拉起。等确认不再需要原版再跑脚本彻底清。

**Q2：`--keep-installer` 什么时候用？**
想留着 `/Applications/MacKMLink.app` 作为「安装器样本」，方便随时重装或继续抓包时用。
代价是它仍可被双击重新解包；如果你要的是「干净机器」，别用它。

**Q3：报错「当前环境无法交互确认；请加 --yes」？**
脚本不在终端里运行（无 `/dev/tty`）。在 Terminal.app 里直接跑，或显式加 `--yes`。

**Q4：报错「请用普通用户运行（不要 sudo）」？**
TCC 与偏好都是按当前用户存的，root 下清理会清错位置。去掉 `sudo` 用普通管理员账户运行即可。

**Q5：`/Applications/MacKMLink.app` 删不掉？**
正常管理员账户可直接删。若报权限不足，按脚本提示手动 `sudo rm -rf "/Applications/MacKMLink.app"`，
然后重跑脚本收尾。

**Q6：卸载后 `tools/capture_login.sh` 里的路径失效了？**
`tools/capture_login.sh` 默认会查找 `~/Library/MacKMLinkFull/MacKMLink.app` 或 `/Applications/MacKMLink.app`。
继续抓包时：从备份解包回来，或干脆改用 `--keep-installer` 保留外壳 + 手动解包。
本仓库脚本只用于「干净卸载」，不负责恢复。

**Q7：脚本会不会把我新版调试用的授权也清掉？**
会有一个已知交叉点：`build/OTiHelper.app` 复用了 `com.oti.GoBridgeDemon` 这个 bundle id。
脚本清理 `com.oti.GoBridgeDemon` 的偏好与 TCC 授权时，**同样会作用于 OTiHelper**。
如果卸载时 OTiHelper 正在使用：卸载后到 系统设置 › 隐私与安全性 › 辅助功能 重新授权即可。

**Q8：想重装原版怎么办？**
插上桥接线，桌面出现 `MacKMLINK` 卷后，从卷里拷 `MacKMLink.app` 到 `/Applications` 再打开
（它会自动解包载荷到 `~/Library/MacKMLinkFull`）；或从第 8 节的备份恢复。

**Q9：脚本会误删别的 `com.oti.*` 或用户文件吗？**
不会。删除范围是固定白名单：两处安装路径、3 个固定 bundle id 的偏好、
`~/Library` 下八个目录里精确匹配 `com.oti.*` 的残留。不扫描、不动文档/下载/其它应用。

**Q10：多用户机器？**
脚本只清**当前用户**的偏好与 TCC 授权；其它账户需要各自登录后各跑一次（安装路径是共享的，
第一份删除后其它账户只剩偏好/授权清理）。

**Q11：重复运行安全吗？**
安全且幂等：全部清掉后会直接提示「未检测到原版安装」，退出码 `0`。

## 10. 安全边界与已知限制

- **只按白名单删除**，不做全文搜索式清理；`/Volumes/MacKMLINK`、桥接线硬件、Windows 端
  GO! Bridge 均不在处理范围。
- **不处理登录项自动化**：原版本身没有自启项；若你曾手动把 `MacKMLink` 加进登录项，
  需要自己在系统设置里移除（脚本会提示检查）。
- **TCC 只能发起 reset**，无法逐条核验；`tccutil` 对不存在的记录静默跳过，系统设置里
  偶尔仍会显示灰项，点「−」即可。
- **通知中心历史**不会立即消失；偏好删除后不会再产生新通知。
- 依赖系统自带的 `bash`（macOS 3.2 兼容写法）、`defaults`、`tccutil`、`lsregister`、
  `du`、`tar`；无第三方依赖、无需 Rosetta。
- 安装路径可用环境变量覆盖（仅供测试/特殊布局）：
  `MAC_KMLINK_SHELL_APP`、`MAC_KMLINK_PAYLOAD_DIR`。
- 若原版被改名/装到非标准路径，脚本检测不到，需要手动删除或改脚本常量。

## 11. 相关文件

| 文件 | 关系 |
|---|---|
| [`tools/uninstall-original.sh`](../tools/uninstall-original.sh) | 本文档所述脚本 |
| [`tools/capture_login.sh`](../tools/capture_login.sh) | 抓原版登录帧，依赖 `~/Library/MacKMLinkFull/MacKMLink.app`（卸载后失效） |
| [`docs/reverse-engineering/RESEARCH.md`](reverse-engineering/RESEARCH.md) | 原版版本、哈希、安装布局的记录 |
| [`docs/reverse-engineering/NATIVE-SCSI-TRANSPORT.md`](reverse-engineering/NATIVE-SCSI-TRANSPORT.md) | 原版/复刻版对 `MacKMLINK` 卷与独占访问的背景 |
