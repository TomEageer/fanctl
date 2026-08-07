#!/bin/bash
# fanctl uninstaller — run as root (sudo ./uninstall.sh)
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

launchctl bootout system/io.fanctl.daemon 2>/dev/null
pkill -f fanctld.py 2>/dev/null
sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID/io.fanctl.menubar" 2>/dev/null
pkill -f fanctl-bar 2>/dev/null

/usr/local/bin/smcfan auto 2>/dev/null   # 风扇交还系统后再删

rm -f /Library/LaunchDaemons/io.fanctl.daemon.plist
rm -f "$REAL_HOME/Library/LaunchAgents/io.fanctl.menubar.plist"
rm -f /usr/local/bin/smcfan /usr/local/bin/fanctl /usr/local/libexec/fanctld.py
rm -rf /Applications/Fanctl.app
rm -f /tmp/fanctl-status.json /tmp/fanctl-cmd
echo "== fanctl 已卸载，风扇已交还系统自动控制（日志 /var/log/fanctl.log 保留）"
