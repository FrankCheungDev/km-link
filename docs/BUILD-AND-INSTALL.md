# KMLink 成品 App 构建与安装指南

本文档说明如何从源码构建原生 Apple Silicon（`arm64`）的 `KMLink.app`，完成签名、自测并安装到本机 `/Applications/KMLink.app` 长期自用；文末也附带了未来如需对外分发时的公证与 DMG 打包流程。

---

## 1. 环境与前置要求

- **系统与架构**：Apple Silicon（`arm64`）、macOS 13.0+（`build.sh` 目标版本 `arm64-apple-macos13.0`）。
- **编译工具**：Command Line Tools（`/Library/Developer/CommandLineTools/usr/bin/clang`、`swiftc`）与 SDK（`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`）。
  - 本项目不依赖 Xcode GUI 工程，也不需要接受 Xcode license。
  - 若使用其它 SDK 或编译器，可通过环境变量 `SDK`、`CLANG`、`SWIFTC` 覆盖。
- **签名证书**：
  - `./build.sh` 默认使用 ad-hoc 签名（`-`），任何用户克隆后均可直接编译运行。
  - 若本机配置了 Apple `Developer ID Application` 证书，可通过 `SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"` 指定，或运行 `./install-local.sh` 自动从本机钥匙串读取证书。使用固定 Developer ID 证书 + Bundle ID（`com.local.kmlink`）签名后，升级覆盖安装不会导致「辅助功能（Accessibility）」授权失效，也便于 `/Applications` 下的 `SMAppService` 登录项工作。

---

## 2. 本机安装自用（Developer ID 一键流程）

在项目根目录执行：

```bash
./install-local.sh
```

> 注意：必须在有权限访问本机钥匙串和 `/Applications` 目录的终端环境执行（在受限沙箱中无法读取签名证书与写入 `/Applications`）。

[`install-local.sh`](../install-local.sh) 会依次完成以下步骤：

1. **强制 Developer ID 编译与签名**：若未指定 `SIGN_IDENTITY`，自动从钥匙串查找首个 `Developer ID Application:` 证书，并以 `REQUIRE_DEV_ID=1` 调用 [`build.sh`](../build.sh)，启用优化编译（C `-O2`、Swift `-O`）与 Hardened Runtime（`--options runtime`）；若找不到证书则报错退出。
2. **校验产物与签名链**：检查主二进制是否为 `arm64` Mach-O，并执行 `codesign --verify --deep --strict` 与 `Authority=Developer ID Application:` 校验。
3. **运行内置自测**：执行 `build/KMLink.app/Contents/MacOS/KMLink --selftest`，确认协议编解码、多块重组、`USBLink` 与 `KMEngine` 几何自测全部通过（`ALL SELFTESTS PASSED`）。
4. **优雅退出旧实例**：通过 `osascript -e 'tell application id "com.local.kmlink" to quit'` 退出正在运行的 `KMLink`（确保 `applicationWillTerminate` 恢复鼠标加速 `MouseScaling` 与 OTi HID 默认属性），超时后再发 `SIGTERM`。
5. **安装到 `/Applications/KMLink.app`**：使用 `ditto` 暂存并原子替换目标路径、清理 `com.apple.quarantine` 属性，并移除旧的 `~/Library/LaunchAgents/com.local.kmlink.agent.plist`，让位于 `/Applications` 的 `SMAppService.mainApp` 接管开机自启。
6. **二次验签并启动**：再次执行 `codesign --verify --deep --strict /Applications/KMLink.app`，随后通过 `open -a /Applications/KMLink.app` 启动。

---

## 3. 仅编译到 `build/`（开发调试）

如果只想重新编译 [`build/KMLink.app`](../build/KMLink.app) 而不安装到 `/Applications`：

```bash
./build.sh
```

[`build.sh`](../build.sh) 的关键行为：

- 优先选择 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`；找不到时再尝试 Xcode SDK 或 `xcrun --show-sdk-path`。
- 编译 [`Sources/SCSITaskShim.c`](../Sources/SCSITaskShim.c) 与 `Sources/*.swift`，链接 `AppKit`、`Carbon`、`IOKit`、`DiskArbitration`。
- 复制 [`Resources/Info.plist`](../Resources/Info.plist) 与 [`Resources/AppIcon.icns`](../Resources/AppIcon.icns)，并统一权限（主程序 `755`，清单与图标 `644`）及清理扩展属性（`xattr -cr`）。
- 默认使用 ad-hoc 签名并开启 Hardened Runtime；若传入 `SIGN_IDENTITY="Developer ID Application: ..."` 且开启 `REQUIRE_DEV_ID=1`，找不到证书时会直接报错退出。

如希望强校验必须使用 Developer ID 签名，可运行：

```bash
SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" REQUIRE_DEV_ID=1 ./build.sh
```

---

## 4. 安装后的首次配置与日常使用注意事项

1. **辅助功能权限**：首次使用键鼠共享时，在「系统设置 › 隐私与安全性 › 辅助功能」勾选 `KMLink`（主窗口在未授权时会显示橙色提示条与 `Open Settings` / `Check` 按钮）。
2. **开机自启**：在设置面板开启 `Launch KMLink when I log in` 后，安装在 `/Applications/KMLink.app` 的版本会优先通过 `SMAppService.mainApp` 注册登录项（见 [`Sources/LaunchAtLogin.swift`](../Sources/LaunchAtLogin.swift)）。
3. **避免与原版 `MacKMLink` 冲突**：`ObtainExclusiveAccess` 需要独占 USB 桥接线的 `IOCompactDiscServices`（LUN 1）。若机器上同时装有原版 `MacKMLink.app` / `GoBridgeDemon`，运行自编版前需先退出原版并卸载其虚拟卷（或使用 [`tools/uninstall-original.sh`](../tools/uninstall-original.sh) 清理原版）。

---

## 5. 验证与排查

### 检查安装签名与二进制

```bash
file /Applications/KMLink.app/Contents/MacOS/KMLink
codesign --verify --deep --strict --verbose=2 /Applications/KMLink.app
codesign -dvv /Applications/KMLink.app 2>&1 | grep -E "Identifier=|TeamIdentifier=|Authority=|flags="
```

### 运行命令行自测与硬件探针

```bash
# 无硬件依赖的完整逻辑自测
/Applications/KMLink.app/Contents/MacOS/KMLink --selftest

# 检查辅助功能授权与 CGEventTap 状态
/Applications/KMLink.app/Contents/MacOS/KMLink --kmcheck

# 需要独占 USB 设备的探针（运行前需先退出正在驻留的 KMLink）
/Applications/KMLink.app/Contents/MacOS/KMLink --usbprobe
/Applications/KMLink.app/Contents/MacOS/KMLink --hidtest
/Applications/KMLink.app/Contents/MacOS/KMLink --switchtest
```

### 查看运行日志

以下两个日志文件均已内置 **2 MB 自动轮转**（超过 2 MB 自动滚动为 `.1` 备份，防止长期挂机占满 `/tmp`）：

- 应用与协议日志：`/tmp/kmlink-runtime.log`（实现见 [`Sources/UI.swift`](../Sources/UI.swift)）
- 底层 SCSI / HID 调整日志：`/tmp/kmlink-scsi.log`（实现见 [`Sources/SCSITaskShim.c`](../Sources/SCSITaskShim.c)）

---

## 6. 附录：将来如需对外分发（公证 + DMG）

本机自用无需 Apple 公证，因为本地构建拷贝无 `com.apple.quarantine` 隔离属性。若日后需要打包发给其他 Mac 使用，避免被 Gatekeeper 拦截，可按以下流程扩展：

1. **启用安全时间戳签名**（去掉 `--timestamp=none`，改用 `--timestamp`，需联网）：

   ```bash
   codesign --force --deep --options runtime --timestamp \
     --sign "Developer ID Application: <Your Name> (<TEAMID>)" \
     build/KMLink.app
   ```

2. **提交 Apple 公证并装订票据**（需提前用 `xcrun notarytool store-credentials` 配置凭据）：

   ```bash
   ditto -c -k --keepParent build/KMLink.app build/KMLink-notarize.zip
   xcrun notarytool submit build/KMLink-notarize.zip --keychain-profile "AC_PASSWORD" --wait
   xcrun stapler staple build/KMLink.app
   spctl --assess --type execute --verbose=4 build/KMLink.app
   ```

3. **制作带 `Applications` 替身的 DMG 并二次公证**：

   ```bash
   mkdir -p build/dmg-root
   cp -R build/KMLink.app build/dmg-root/
   ln -s /Applications build/dmg-root/Applications
   hdiutil create -volname "KMLink" -srcfolder build/dmg-root -ov -format UDZO dist/KMLink-arm64.dmg
   codesign --force --timestamp --sign "Developer ID Application: <Your Name> (<TEAMID>)" dist/KMLink-arm64.dmg
   xcrun notarytool submit dist/KMLink-arm64.dmg --keychain-profile "AC_PASSWORD" --wait
   xcrun stapler staple dist/KMLink-arm64.dmg
   ```
