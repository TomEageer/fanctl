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
# 等旧实例完全退出（bootout 是异步的，紧跟 bootstrap 会竞态失败）
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print system/io.fanctl.daemon >/dev/null 2>&1 || break
    sleep 0.5
done
launchctl bootstrap system /Library/LaunchDaemons/io.fanctl.daemon.plist \
    || { sleep 2; launchctl bootstrap system /Library/LaunchDaemons/io.fanctl.daemon.plist; }
launchctl print system/io.fanctl.daemon >/dev/null 2>&1 || { echo "错误：后台服务注册失败"; exit 1; }
echo ok
