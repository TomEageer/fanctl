#!/bin/bash
# 源码安装：把构建产物摆成资源目录，交给规范安装器执行（与 App 内安装同一实现）
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行：sudo ./install.sh"; exit 1; }
cd "$(dirname "$0")"
[ -f build/smcfan ] || { echo "请先 make"; exit 1; }

REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp build/smcfan daemon/fanctld.py bin/fanctl uninstall.sh \
   launchd/io.fanctl.daemon.plist launchd/io.fanctl.restore.plist "$STAGE/"
[ -x /opt/homebrew/bin/macmon ] && cp /opt/homebrew/bin/macmon "$STAGE/macmon"

bash scripts/install-helper.sh "$STAGE" >/dev/null

# 菜单栏应用（源码安装才做；App 内安装时应用本体已就位）
rm -rf /Applications/Fanctl.app
cp -R build/Fanctl.app /Applications/
mkdir -p "$REAL_HOME/Library/LaunchAgents"
install -o "$REAL_USER" -m 644 launchd/io.fanctl.menubar.plist "$REAL_HOME/Library/LaunchAgents/"
sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID/io.fanctl.menubar" 2>/dev/null || true
sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" \
    "$REAL_HOME/Library/LaunchAgents/io.fanctl.menubar.plist"

echo "== fanctl 安装完成：后台服务已启动，菜单栏应显示温度。fanctl status 查看状态。"
