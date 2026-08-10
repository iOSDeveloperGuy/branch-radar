PREFIX ?= $(HOME)/.local

.PHONY: build test release install clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

install: release
	install -d "$(PREFIX)/bin"
	install -m 755 .build/release/branch-radar "$(PREFIX)/bin/branch-radar"
	@echo "Installed branch-radar to $(PREFIX)/bin/branch-radar"

clean:
	swift package clean
