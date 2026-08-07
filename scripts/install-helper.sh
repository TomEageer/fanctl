#!/bin/bash
# fanctl 后台服务安装器 — 由 Fanctl.app 首次启动时以管理员权限调用
# 用法: install-helper.sh <App 的 Resources 目录>
set -e
RES="$1"
[ -d "$RES" ] || { echo "resources dir not found"; exit 1; }

mkdir -p /usr/local/bin /usr/local/libexec
install -o root -g wheel -m 755 "$RES/smcfan"      /usr/local/bin/smcfan
install -o root -g wheel -m 644 "$RES/fanctld.py"  /usr/local/libexec/fanctld.py
# 温度采样器：优先用用户已装的 homebrew macmon，否则用 App 自带副本
if [ ! -x /opt/homebrew/bin/macmon ] && [ -f "$RES/macmon" ]; then
    install -o root -g wheel -m 755 "$RES/macmon" /usr/local/bin/fanctl-macmon
fi
install -o root -g wheel -m 644 "$RES/io.fanctl.daemon.plist" /Library/LaunchDaemons/
launchctl bootout system/io.fanctl.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/io.fanctl.daemon.plist
echo ok
