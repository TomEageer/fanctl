#!/bin/bash
# fanctl 规范安装器 — 唯一的安装实现（App 内置安装与源码 install.sh 都调用它）
# 用法: sudo install-helper.sh <资源目录>
# 资源目录需包含: smcfan fanctld.py fanctl uninstall.sh io.fanctl.daemon.plist
#                io.fanctl.restore.plist [macmon]
set -euo pipefail

RES="${1:-}"
[ -d "$RES" ] || { echo "错误：资源目录不存在：$RES"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "错误：需要管理员权限"; exit 1; }

LIBEXEC=/usr/local/libexec/fanctl
RUNDIR=/usr/local/var/fanctl

# --- 依赖预检：守护进程需要 python3（干净系统上它只是 xcselect 桩） ---------
if ! /usr/bin/python3 -c 'pass' >/dev/null 2>&1; then
    echo "错误：系统缺少可用的 python3。请先运行 xcode-select --install 安装命令行工具后重试。"
    echo "ERROR: no working /usr/bin/python3. Run 'xcode-select --install' first."
    exit 2
fi

# --- 目录：root 拥有且非 root 不可写（守护进程会校验，不合规将拒绝运行） -----
install -d -o root -g wheel -m 755 "$LIBEXEC" "$RUNDIR"
install -d -o root -g admin -m 770 "$RUNDIR/cmd"      # 命令通道：仅管理员组可投递

# --- 二进制与脚本 ------------------------------------------------------------
install -o root -g wheel -m 755 "$RES/smcfan"        "$LIBEXEC/smcfan"
install -o root -g wheel -m 644 "$RES/fanctld.py"    "$LIBEXEC/fanctld.py"
install -o root -g wheel -m 755 "$RES/fanctl"        "$LIBEXEC/fanctl"
install -o root -g wheel -m 755 "$RES/uninstall.sh"  "$LIBEXEC/uninstall.sh"
[ -f "$RES/macmon" ] && install -o root -g wheel -m 755 "$RES/macmon" "$LIBEXEC/macmon"
ln -sfn "$LIBEXEC/fanctl" /usr/local/bin/fanctl 2>/dev/null || true

install -o root -g wheel -m 644 "$RES/io.fanctl.daemon.plist"  /Library/LaunchDaemons/
install -o root -g wheel -m 644 "$RES/io.fanctl.restore.plist" /Library/LaunchDaemons/

# --- 迁移：清掉旧版本留下的不安全路径与命名 ----------------------------------
launchctl bootout system/com.tom.fanctl 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.tom.fanctl.plist \
      /usr/local/bin/smcfan /usr/local/libexec/fanctl.py /usr/local/libexec/fanctld.py \
      /usr/local/bin/fanctl-macmon \
      /tmp/fanctl-status.json /tmp/fanctl-cmd /tmp/fanctl-history.jsonl
[ -f /usr/local/var/fanctl/model.json ] || true   # 旧模型文件位置相同，保留

# --- 注册服务：bootout 是异步的，必须排干后再 bootstrap ----------------------
boot_service() {
    local label="$1" plist="$2"
    launchctl bootout "system/$label" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "system/$label" >/dev/null 2>&1 || break
        sleep 0.5
    done
    launchctl bootstrap system "$plist" 2>/dev/null \
        || { sleep 2; launchctl bootstrap system "$plist" 2>/dev/null || true; }
}
boot_service io.fanctl.restore /Library/LaunchDaemons/io.fanctl.restore.plist
boot_service io.fanctl.daemon  /Library/LaunchDaemons/io.fanctl.daemon.plist

launchctl print system/io.fanctl.daemon >/dev/null 2>&1 \
    || { echo "错误：后台服务注册失败"; exit 3; }
echo ok
