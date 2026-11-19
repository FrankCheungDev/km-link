#!/bin/bash
# ============================================================================
# uninstall-original.sh — 一键卸载原版 MacKMLink（OTi GO! Bridge）
#
# 原版在 macOS 上的完整安装面只有下面这些，脚本逐项处理：
#   1. /Applications/MacKMLink.app          安装外壳（com.oti.MacKMLinkShell），
#                                           内含 MacKMLinkFull.tgz 载荷
#   2. ~/Library/MacKMLinkFull/             外壳解包出的载荷
#                                           （com.oti.MacKMLinkWithGOBridge +
#                                            GoBridgeDemon + MacKMLinkShell）
#   3. ~/Library/Preferences/com.oti.*.plist 偏好
#   4. 辅助功能 / 输入监控 的 TCC 授权
#   5. LaunchServices 陈旧注册、缓存等零散残留
#
# 原版没有 launchd 项、没有特权 helper、没有 pkg 收据、没有 DriverKit 扩展。
# 桥接线自带的虚拟光盘卷 /Volumes/MacKMLINK 属于硬件而非安装内容，脚本不会动它。
#
# 用法：
#   ./tools/uninstall-original.sh                 交互确认，默认先备份到 ~/Desktop
#   ./tools/uninstall-original.sh --yes           跳过确认（仍然备份）
#   ./tools/uninstall-original.sh --no-backup     不备份
#   ./tools/uninstall-original.sh --dry-run       只打印计划，不做任何修改
#   ./tools/uninstall-original.sh --keep-installer
#                                                 保留 /Applications 里的外壳（方便重装），
#                                                 只清载荷、偏好与授权
#   ./tools/uninstall-original.sh --backup-dir DIR
#                                                 备份目录（默认 ~/Desktop）
#
# 备份是 tar.gz，里面保留绝对路径（去掉前导 /）。恢复：
#   sudo tar -xzf <备份>.tgz -C /
# ============================================================================

set -o pipefail

# 两个安装路径允许用环境变量覆盖（仅供测试/特殊布局；默认即真实路径）
SHELL_APP="${MAC_KMLINK_SHELL_APP:-/Applications/MacKMLink.app}"
PAYLOAD_DIR="${MAC_KMLINK_PAYLOAD_DIR:-$HOME/Library/MacKMLinkFull}"
PREF_BUNDLE_IDS=(com.oti.MacKMLinkWithGOBridge com.oti.GoBridgeDemon com.oti.MacKMLinkShell)
PROC_PATTERN='MacKMLink\.app/Contents/MacOS|MacKMLinkShell\.app/Contents/MacOS|GoBridgeDemon'
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ASSUME_YES=0
DO_BACKUP=1
DRY_RUN=0
KEEP_INSTALLER=0
BACKUP_DIR="$HOME/Desktop"
RC=0

# ---------------------------------------------------------------- 输出辅助 ---
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; DIM=""; NC=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YELLOW" "$NC" "$*"; }
fail() { printf '  %s✘%s %s\n' "$RED" "$NC" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$NC"; }
die()  { printf '%s错误：%s%s\n' "$RED" "$*" "$NC" >&2; exit 2; }

usage() {
    # 只打印文件头部的注释块（遇到第一行非注释即停止）
    awk 'NR == 1 { next }
         /^#!/ { next }
         /^# =+$/ { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "$0"
}

# ---------------------------------------------------------------- 参数解析 ---
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)          ASSUME_YES=1 ;;
        --no-backup)       DO_BACKUP=0 ;;
        --dry-run|-n)      DRY_RUN=1 ;;
        --keep-installer)  KEEP_INSTALLER=1 ;;
        --backup-dir)      [ $# -ge 2 ] || die "--backup-dir 需要一个目录参数"
                           BACKUP_DIR="$2"; shift ;;
        --backup-dir=*)    BACKUP_DIR="${1#*=}" ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "未知参数：$1（用 --help 查看用法）" ;;
    esac
    shift
done

# ---------------------------------------------------------------- 前置检查 ---
[ "$(id -u)" -ne 0 ] || die "请用普通用户运行（不要 sudo）。TCC 与偏好属于当前用户，root 下清理会清错地方。"
[ -n "${HOME:-}" ] && [ "$HOME" != "/" ] || die "HOME 环境变量异常：'${HOME:-<未设置>}'"

# ---------------------------------------------------------------- 现状探测 ---
app_found=0; payload_found=0; pref_found=0; proc_found=0
[ -d "$SHELL_APP" ]   && app_found=1
[ -d "$PAYLOAD_DIR" ] && payload_found=1
for bid in "${PREF_BUNDLE_IDS[@]}"; do
    [ -f "$HOME/Library/Preferences/$bid.plist" ] && pref_found=1
done
if pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then proc_found=1; fi

# 零散残留（缓存 / 保存状态 / 容器 / 日志 / HTTPStorages / WebKit / LaunchAgents）
# 注意：macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound，所以这里不用 -u，
#       并且逐个 glob 展开后只保留真实存在的路径。
shopt -s nullglob
leftovers=()
for p in \
    "$HOME/Library/Saved Application State"/com.oti.* \
    "$HOME/Library/Caches"/com.oti.* \
    "$HOME/Library/Application Support"/com.oti.* \
    "$HOME/Library/Logs"/com.oti.* \
    "$HOME/Library/Containers"/com.oti.* \
    "$HOME/Library/HTTPStorages"/com.oti.* \
    "$HOME/Library/WebKit"/com.oti.* \
    "$HOME/Library/LaunchAgents"/com.oti.*.plist
do
    [ -e "$p" ] && leftovers+=("$p")
done

# LaunchServices 里登记过的原版路径（删前反注册，避免残留幽灵图标）
UNREGISTER_PATHS=()
[ -d "$SHELL_APP" ]                    && UNREGISTER_PATHS+=("$SHELL_APP")
[ -d "$PAYLOAD_DIR/MacKMLink.app" ]    && UNREGISTER_PATHS+=("$PAYLOAD_DIR/MacKMLink.app")
[ -d "$PAYLOAD_DIR/MacKMLinkShell.app" ] && UNREGISTER_PATHS+=("$PAYLOAD_DIR/MacKMLinkShell.app")
[ -d "$PAYLOAD_DIR/MacKMLink.app/Contents/PlugIns/GoBridgeDemon.app" ] && \
    UNREGISTER_PATHS+=("$PAYLOAD_DIR/MacKMLink.app/Contents/PlugIns/GoBridgeDemon.app")

size_of() { [ -e "$1" ] && du -sh -- "$1" 2>/dev/null | awk '{print $1}' || echo "?"; }

# ---------------------------------------------------------------- 计划展示 ---
step "卸载计划"
say "  将执行：停止进程 → 备份 → 删除安装内容 → 清偏好 → 重置授权 → 校验"
say ""
if [ "$KEEP_INSTALLER" -eq 1 ]; then
    say "  安装外壳：保留（--keep-installer）"
elif [ "$app_found" -eq 1 ]; then
    say "  安装外壳：删除 ${SHELL_APP}（$(size_of "$SHELL_APP")）"
else
    say "  安装外壳：不存在"
fi
if [ "$payload_found" -eq 1 ]; then
    say "  解包载荷：删除 ${PAYLOAD_DIR}（$(size_of "$PAYLOAD_DIR")）"
else
    say "  解包载荷：不存在"
fi
if [ "$pref_found" -eq 1 ]; then
    say "  偏好设置：删除 ${PREF_BUNDLE_IDS[*]}"
else
    say "  偏好设置：不存在"
fi
if [ "${#leftovers[@]}" -gt 0 ]; then
    say "  零散残留：删除 ${#leftovers[@]} 项（缓存/保存状态/日志等）"
    for p in "${leftovers[@]}"; do note "    $p"; done
fi
if [ "$proc_found" -eq 1 ]; then
    say "  运行进程：终止（MacKMLink / MacKMLinkShell / GoBridgeDemon）"
else
    say "  运行进程：无"
fi
say "  TCC 授权：重置 Accessibility / ListenEvent（$([[ "$DRY_RUN" -eq 1 ]] && echo '预演' || echo '需要时在系统设置里点 − 兜底')）"
if [ "$DO_BACKUP" -eq 1 ]; then
    say "  备份目录：${BACKUP_DIR}（tar.gz）"
else
    say "  备份：跳过（--no-backup）"
fi

if [ "$app_found" -eq 0 ] && [ "$payload_found" -eq 0 ] && [ "$pref_found" -eq 0 ] \
   && [ "${#leftovers[@]}" -eq 0 ] && [ "$proc_found" -eq 0 ]; then
    say ""
    ok "未检测到原版安装，也没有偏好/缓存残留，无需卸载。"
    note "若“系统设置 › 隐私与安全性 › 辅助功能”里仍留有 MacKMLink 条目，手动点「−」移除即可。"
    exit 0
fi

# ---------------------------------------------------------------- 预演模式 ---
if [ "$DRY_RUN" -eq 1 ]; then
    step "预演（--dry-run，未做任何修改）"
    [ "$proc_found" -eq 1 ] && note "将执行：pkill -f '$PROC_PATTERN'"
    [ "$DO_BACKUP" -eq 1 ]  && note "将执行：tar -czf \"$BACKUP_DIR/MacKMLink-original-<时间戳>.tgz\" ..."
    for p in "${UNREGISTER_PATHS[@]}"; do note "将执行：lsregister -u \"$p\""; done
    [ "$KEEP_INSTALLER" -eq 0 ] && [ "$app_found" -eq 1 ] && note "将执行：rm -rf -- \"$SHELL_APP\""
    [ "$payload_found" -eq 1 ] && note "将执行：rm -rf -- \"$PAYLOAD_DIR\""
    for bid in "${PREF_BUNDLE_IDS[@]}"; do
        note "将执行：defaults delete \"$bid\" 2>/dev/null（若存在）"
        note "将执行：tccutil reset Accessibility \"$bid\" + ListenEvent"
    done
    for p in "${leftovers[@]}"; do note "将执行：rm -rf -- \"$p\""; done
    say ""
    ok "预演结束，未改动任何文件。去掉 --dry-run 即为实际执行。"
    exit 0
fi

# ---------------------------------------------------------------- 人工确认 ---
if [ "$ASSUME_YES" -eq 0 ]; then
    say ""
    printf '确认卸载原版 MacKMLink？%s输入 yes 继续，其他任意键取消：%s' "$BOLD" "$NC"
    if [ -r /dev/tty ]; then
        read -r answer < /dev/tty || answer=""
    else
        die "当前环境无法交互确认；请加 --yes 显式确认"
    fi
    [ "$answer" = "yes" ] || { say ""; say "已取消，未做任何修改。"; exit 1; }
fi

# ---------------------------------------------------------------- 备份 ---
do_backup() {
    local stamp dest rel=() p
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p -- "$BACKUP_DIR" 2>/dev/null || { fail "备份目录不可写：$BACKUP_DIR"; return 1; }
    dest="$BACKUP_DIR/MacKMLink-original-${stamp}.tgz"

    [ "$KEEP_INSTALLER" -eq 0 ] && [ -d "$SHELL_APP" ] && rel+=("${SHELL_APP#/}")
    [ -d "$PAYLOAD_DIR" ] && rel+=("${PAYLOAD_DIR#/}")
    for bid in "${PREF_BUNDLE_IDS[@]}"; do
        p="$HOME/Library/Preferences/$bid.plist"
        [ -f "$p" ] && rel+=("${p#/}")
    done
    for p in "${leftovers[@]}"; do rel+=("${p#/}"); done
    [ "${#rel[@]}" -gt 0 ] || { note "没有可备份的内容，跳过备份"; return 0; }

    # 注意：bsdtar 不认 `--` 结束选项，这里不能用（会把 "--" 当成 -f 的参数）
    if tar -czf "$dest" -C / "${rel[@]}" 2>/dev/null; then
        ok "已备份到 ${dest}（$(du -sh -- "$dest" 2>/dev/null | awk '{print $1}')）"
        note "恢复：sudo tar -xzf \"$dest\" -C /"
        return 0
    fi
    fail "备份失败（${dest}），已中止卸载，未删除任何文件"
    return 1
}

if [ "$DO_BACKUP" -eq 1 ]; then
    step "备份"
    do_backup || exit 1
fi

# ---------------------------------------------------------------- 终止进程 ---
step "终止原版进程"
if pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then
    pkill -f "$PROC_PATTERN" 2>/dev/null
    for _ in 1 2 3 4 5; do
        pgrep -f "$PROC_PATTERN" >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then
        pkill -9 -f "$PROC_PATTERN" 2>/dev/null
        sleep 1
    fi
    if pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then
        fail "仍有进程存活："; pgrep -fl -f "$PROC_PATTERN" | sed 's/^/      /'
        RC=1
    else
        ok "进程已退出"
    fi
else
    ok "没有在运行的原版进程"
fi

# ---------------------------------------------------------- LaunchServices ---
step "反注册 LaunchServices"
for p in "${UNREGISTER_PATHS[@]}"; do
    if [ -x "$LSR" ]; then
        "$LSR" -u "$p" >/dev/null 2>&1 || true
        ok "已反注册 $p"
    else
        note "找不到 lsregister，跳过"
        break
    fi
done

# ---------------------------------------------------------------- 删除内容 ---
remove_path() {
    local p="$1"
    [ -e "$p" ] || { note "已不存在：$p"; return 0; }
    if rm -rf -- "$p" 2>/dev/null && [ ! -e "$p" ]; then
        ok "已删除 $p"
        return 0
    fi
    fail "删除失败（权限不足？）：$p"
    note "  可手动执行：sudo rm -rf \"$p\""
    RC=1
    return 1
}

step "删除安装内容"
if [ "$KEEP_INSTALLER" -eq 0 ] && [ "$app_found" -eq 1 ]; then
    remove_path "$SHELL_APP"
elif [ "$KEEP_INSTALLER" -eq 1 ] && [ -d "$SHELL_APP" ]; then
    note "按 --keep-installer 保留 $SHELL_APP"
fi
if [ "$payload_found" -eq 1 ]; then
    remove_path "$PAYLOAD_DIR"
fi

step "清理偏好设置"
for bid in "${PREF_BUNDLE_IDS[@]}"; do
    if defaults read "$bid" >/dev/null 2>&1; then
        defaults delete "$bid" >/dev/null 2>&1 || true
        ok "已删除偏好域 $bid"
    fi
    remove_path "$HOME/Library/Preferences/$bid.plist" >/dev/null 2>&1 || true
done

if [ "${#leftovers[@]}" -gt 0 ]; then
    step "清理零散残留"
    for p in "${leftovers[@]}"; do remove_path "$p"; done
fi

# ---------------------------------------------------------------- TCC 授权 ---
step "重置隐私授权（辅助功能 / 输入监控）"
if command -v tccutil >/dev/null 2>&1; then
    for bid in "${PREF_BUNDLE_IDS[@]}"; do
        for svc in Accessibility ListenEvent; do
            tccutil reset "$svc" "$bid" >/dev/null 2>&1 || true
        done
    done
    ok "已对 ${#PREF_BUNDLE_IDS[@]} 个 bundle id 执行 tccutil reset（无记录时静默跳过）"
else
    warn "找不到 tccutil，请手动在 系统设置 › 隐私与安全性 › 辅助功能 里移除"
fi

# ---------------------------------------------------------------- 校验 ---
step "校验"
remaining=0
[ "$KEEP_INSTALLER" -eq 0 ] && [ -e "$SHELL_APP" ] && { fail "仍存在：$SHELL_APP"; remaining=1; }
[ -e "$PAYLOAD_DIR" ] && { fail "仍存在：$PAYLOAD_DIR"; remaining=1; }
for bid in "${PREF_BUNDLE_IDS[@]}"; do
    [ -f "$HOME/Library/Preferences/$bid.plist" ] && { fail "仍存在偏好：$bid.plist"; remaining=1; }
done
pgrep -f "$PROC_PATTERN" >/dev/null 2>&1 && { fail "仍有进程在运行"; remaining=1; }
[ "$remaining" -eq 0 ] && ok "安装内容、偏好、进程均已清理干净"
[ "$remaining" -eq 0 ] || RC=1

if [ "$KEEP_INSTALLER" -eq 1 ] && [ -d "$SHELL_APP" ]; then
    note "注意：外壳仍在 /Applications，双击会重新解包出 ~/Library/MacKMLinkFull"
fi

if [ -d /Volumes/MacKMLINK ]; then
    say ""
    warn "检测到 /Volumes/MacKMLINK（桥接线自带的虚拟光盘卷），它不属于安装内容。"
    note "  需要它消失就拔掉桥接线的 Mac 端；想重装时重新插上即可。"
fi

say ""
if [ "$RC" -eq 0 ]; then
    say "${GREEN}${BOLD}卸载完成。${NC}"
    say "如有残留图标，注销/重启一次即可刷新；通知中心条目会随偏好删除失效。"
else
    say "${YELLOW}${BOLD}卸载完成，但有项目未能清理，见上面的 ✘ 提示。${NC}"
fi
say "别忘了：系统设置 › 通用 › 登录项与扩展 里若还有 MacKMLink 项，点「−」移除。"
exit "$RC"
