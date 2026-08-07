VERSION := 1.9.4

.PHONY: all install uninstall clean dist

all: build/smcfan build/Fanctl.app

build/smcfan: smc/smcfan.c
	@mkdir -p build
	clang -O2 -mmacosx-version-min=13.0 -framework IOKit -o $@ $<

# 自包含 App：菜单栏程序 + 后台服务全套组件打进 Resources，
# 首次启动由 App 引导安装（拖进「应用程序」即可用）
build/Fanctl.app: menubar/main.swift menubar/Info.plist build/smcfan \
                  daemon/fanctld.py launchd/io.fanctl.daemon.plist scripts/install-helper.sh
	@mkdir -p build/Fanctl.app/Contents/MacOS build/Fanctl.app/Contents/Resources
	swiftc -O -target arm64-apple-macos13.0 -o build/Fanctl.app/Contents/MacOS/fanctl-bar menubar/main.swift
	cp menubar/Info.plist build/Fanctl.app/Contents/Info.plist
	cp build/smcfan daemon/fanctld.py launchd/io.fanctl.daemon.plist scripts/install-helper.sh \
	   assets/AppIcon.icns \
	   build/Fanctl.app/Contents/Resources/
	@if [ -x /opt/homebrew/bin/macmon ]; then \
	    cp /opt/homebrew/bin/macmon build/Fanctl.app/Contents/Resources/macmon; \
	    echo "bundled macmon"; \
	else echo "warn: macmon not found, app will require 'brew install macmon'"; fi
	codesign --force --deep --sign - build/Fanctl.app

dist: all
	cd build && ditto -c -k --keepParent Fanctl.app Fanctl-$(VERSION).zip && cp Fanctl-$(VERSION).zip Fanctl.zip
	@echo "== build/Fanctl-$(VERSION).zip (+ 固定名 Fanctl.zip，发版时两个都上传保持官网直链常青)"

install: all
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

clean:
	rm -rf build
