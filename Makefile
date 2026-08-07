.PHONY: all install uninstall clean

all: build/smcfan build/Fanctl.app

build/smcfan: smc/smcfan.c
	@mkdir -p build
	clang -O2 -framework IOKit -o $@ $<

build/Fanctl.app: menubar/main.swift menubar/Info.plist
	@mkdir -p build/Fanctl.app/Contents/MacOS
	swiftc -O -o build/Fanctl.app/Contents/MacOS/fanctl-bar menubar/main.swift
	cp menubar/Info.plist build/Fanctl.app/Contents/Info.plist
	codesign --force --sign - build/Fanctl.app

install: all
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

clean:
	rm -rf build
