#!/bin/bash
# fanctl installer — run as root (sudo ./install.sh)
set -e
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

[ -x /opt/homebrew/bin/macmon ] || { echo "缺依赖 macmon: brew install macmon"; exit 1; }
[ -f build/smcfan ] || { echo "请先 make"; exit 1; }

# 停掉旧版本（含早期 com.tom.fanctl 命名）
launchctl bootout system/com.tom.fanctl  2>/dev/null || true
rm -f /Library/LaunchDaemons/com.tom.fanctl.plist /usr/local/libexec/fanctl.py
pkill -f fanctld.py 2>/dev/null || true
pkill -f fanctl.py  2>/dev/null || true

mkdir -p /usr/local/bin /usr/local/libexec
install -o root -g wheel -m 755 build/smcfan       /usr/local/bin/smcfan
install -o root -g wheel -m 755 bin/fanctl         /usr/local/bin/fanctl
install -o root -g wheel -m 644 daemon/fanctld.py  /usr/local/libexec/fanctld.py
install -o root -g wheel -m 644 launchd/io.fanctl.daemon.plist /Library/LaunchDaemons/
launchctl bootout system/io.fanctl.daemon 2>/dev/null || true
# 等旧实例完全退出（bootout 是异步的，紧跟 bootstrap 会竞态失败）
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print system/io.fanctl.daemon >/dev/null 2>&1 || break
    sleep 0.5
done
launchctl bootstrap system /Library/LaunchDaemons/io.fanctl.daemon.plist \
    || { sleep 2; launchctl bootstrap system /Library/LaunchDaemons/io.fanctl.daemon.plist; }
launchctl print system/io.fanctl.daemon >/dev/null 2>&1 || { echo "错误：后台服务注册失败"; exit 1; }

rm -rf /Applications/Fanctl.app
cp -R build/Fanctl.app /Applications/
mkdir -p "$REAL_HOME/Library/LaunchAgents"
install -o "$REAL_USER" -m 644 launchd/io.fanctl.menubar.plist "$REAL_HOME/Library/LaunchAgents/"
sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID/io.fanctl.menubar" 2>/dev/null || true
sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" "$REAL_HOME/Library/LaunchAgents/io.fanctl.menubar.plist"

echo "== fanctl 安装完成：守护进程已启动，菜单栏应显示温度。fanctl status 查看状态。"
