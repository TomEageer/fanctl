#!/bin/bash
# fanctl 卸载器 — 顺序固定：先交还风扇控制，再停服务，最后删文件
# 用法: sudo uninstall.sh [--keep-app]
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

# 1) 风扇交还系统（在删掉 smcfan 之前，且趁守护进程还活着）
/usr/local/libexec/fanctl/smcfan auto 2>/dev/null || /usr/local/bin/smcfan auto 2>/dev/null || true

# 2) 停服务
launchctl bootout system/io.fanctl.daemon 2>/dev/null || true
launchctl bootout system/io.fanctl.restore 2>/dev/null || true
launchctl bootout system/com.tom.fanctl 2>/dev/null || true
pkill -f fanctld.py 2>/dev/null || true
sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID/io.fanctl.menubar" 2>/dev/null || true
pkill -f fanctl-bar 2>/dev/null || true

# 3) 再交还一次（守护进程退出过程中可能又写过 SMC）
/usr/local/libexec/fanctl/smcfan auto 2>/dev/null || true
sleep 1

# 4) 删文件
rm -f /Library/LaunchDaemons/io.fanctl.daemon.plist \
      /Library/LaunchDaemons/io.fanctl.restore.plist \
      /Library/LaunchDaemons/com.tom.fanctl.plist \
      "$REAL_HOME/Library/LaunchAgents/io.fanctl.menubar.plist" \
      /usr/local/bin/fanctl /usr/local/bin/smcfan /usr/local/libexec/fanctld.py \
      /tmp/fanctl-status.json /tmp/fanctl-cmd /tmp/fanctl-history.jsonl
rm -rf /usr/local/libexec/fanctl /usr/local/var/fanctl
[ "${1:-}" = "--keep-app" ] || rm -rf /Applications/Fanctl.app

echo "== fanctl 已卸载，风扇已交还系统控制（日志 /var/log/fanctl.log 保留）"
