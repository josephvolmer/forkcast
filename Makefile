# Forkcast — build & install
#
#   make              build Forkcast.app into ./build
#   make install      install to /Applications, link the `forkcast` CLI + man page, (re)launch
#   make uninstall    remove the app, CLI link and man page (keeps your data)
#   make help         list all targets
#
# Override locations:  make install APPS_DIR=~/Applications BIN_DIR=/usr/local/bin MAN_DIR=/usr/local/share/man/man1

APP_NAME  := Forkcast
# Version: from the latest git tag (v1.2.3 → 1.2.3) unless given, e.g. `make VERSION=2.1.0`.
VERSION   ?= $(shell git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)
ifeq ($(strip $(VERSION)),)
VERSION   := 2.0.0
endif
BUILD_NUM ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
APPS_DIR  ?= /Applications
BIN_DIR   ?= $(HOME)/.local/bin
MAN_DIR   ?= $(HOME)/.local/share/man/man1
DATA_DIR  := $(HOME)/Library/Application Support/Forkcast

BUILD_DIR := .build/arm64-apple-macosx/release
APP       := build/$(APP_NAME).app
CLI       := $(APP)/Contents/Helpers/forkcast
MANPAGE   := $(APP)/Contents/Resources/forkcast.1
SOURCES   := $(shell find Sources -name '*.swift') Package.swift
ICNS      := Resources/AppIcon.icns
MENUICON  := Resources/MenuIcon.png Resources/MenuIcon@2x.png

FORCE:

.PHONY: all app build icon menuicon man pkg install uninstall run open clean help check

all: app

help:
	@echo "make            build $(APP)"
	@echo "make install    install to $(APPS_DIR), link $(BIN_DIR)/forkcast and $(MAN_DIR)/forkcast.1, launch"
	@echo "make uninstall  remove app, CLI link and man page (data in '$(DATA_DIR)' is kept)"
	@echo "make run        build and open the dashboard from ./build (without installing)"
	@echo "make pkg        build a double-click installer: build/Forkcast-<version>.pkg (app + CLI + man page)"
	@echo "make icon       regenerate $(ICNS) from icon.png (menu bar icon: fork.png)"
	@echo "make man        print the generated man page (roff)"
	@echo "make check      build, then smoke-test the CLI help"
	@echo "make clean      remove build products"

# Compile both executables (the app and the CLI).
build: $(BUILD_DIR)/Forkcast $(BUILD_DIR)/ForkcastCLI

# (one `swift build` produces both; macOS ships make 3.81, so no grouped targets)
$(BUILD_DIR)/Forkcast: $(SOURCES)
	swift build -c release --arch arm64

$(BUILD_DIR)/ForkcastCLI: $(BUILD_DIR)/Forkcast
	@test -f $@ && touch $@

# App icon: rebuilt whenever icon.png changes.
icon: $(ICNS)

$(ICNS): icon.png scripts/make-icon.swift
	@rm -rf build/AppIcon.iconset && mkdir -p build
	swift scripts/make-icon.swift icon.png build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(ICNS)
	@rm -rf build/AppIcon.iconset

# Menu bar icon (template image: macOS tints it for light/dark menu bars). Rebuilt when fork.png changes.
menuicon: $(MENUICON)

Resources/MenuIcon.png: fork.png
	sips -Z 18 fork.png --out $@ >/dev/null

Resources/MenuIcon@2x.png: fork.png
	sips -Z 36 fork.png --out $@ >/dev/null

# Assemble and sign the bundle. The CLI lives in Contents/Helpers (macOS file names are
# case-insensitive, so `forkcast` can't sit next to the `Forkcast` executable).
app: $(APP)/Contents/Info.plist

$(APP)/Contents/Info.plist: $(BUILD_DIR)/Forkcast $(BUILD_DIR)/ForkcastCLI $(ICNS) $(MENUICON) Resources/Info.plist FORCE
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp $(BUILD_DIR)/Forkcast $(APP)/Contents/MacOS/Forkcast
	cp $(BUILD_DIR)/ForkcastCLI $(CLI)
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	cp $(MENUICON) $(APP)/Contents/Resources/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(BUILD_NUM)" $(APP)/Contents/Info.plist
	$(CLI) help --man > $(MANPAGE)
	codesign --force --sign - $(CLI)
	codesign --force --sign - $(APP)
	@echo "Built $(APP) (version $(VERSION), build $(BUILD_NUM))"

# Installer package: Forkcast.app → /Applications; postinstall links /usr/local/bin/forkcast and the man page.
# Packages the app as already built (so a Developer ID signature applied beforehand is kept).
PKG := build/$(APP_NAME)-$(VERSION).pkg

pkg:
	@test -d $(APP) || $(MAKE) app
	@rm -rf build/pkgroot build/pkgres build/$(APP_NAME)-component.pkg
	@mkdir -p build/pkgroot/Applications build/pkgres
	ditto $(APP) build/pkgroot/Applications/$(APP_NAME).app
	pkgbuild --analyze --root build/pkgroot build/component.plist >/dev/null
	plutil -replace 0.BundleIsRelocatable -bool false build/component.plist
	plutil -replace 0.BundleOverwriteAction -string upgrade build/component.plist
	pkgbuild --root build/pkgroot --component-plist build/component.plist --scripts pkg/scripts \
		--identifier local.forkcast --version $(VERSION) --install-location / build/$(APP_NAME)-component.pkg
	cp pkg/resources/*.html build/pkgres/ && cp LICENSE build/pkgres/LICENSE.txt
	sed 's/@VERSION@/$(VERSION)/' pkg/distribution.xml > build/distribution.xml
	productbuild --distribution build/distribution.xml --resources build/pkgres --package-path build $(PKG)
	@rm -rf build/pkgroot build/pkgres build/component.plist build/$(APP_NAME)-component.pkg build/distribution.xml
	@echo "Built $(PKG)"

man: build
	@$(BUILD_DIR)/ForkcastCLI help --man

check: app
	$(CLI) --version
	$(CLI) help > /dev/null
	$(CLI) help --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["commands"]), "commands documented")'
	$(CLI) check 'battery > 25 and not on_ac'
	@for c in $$($(CLI) help --json | python3 -c 'import json,sys; print(" ".join(c["name"] for c in json.load(sys.stdin)["commands"]))'); do \
		$(CLI) $$c --help > /dev/null || { echo "help failed for $$c"; exit 1; }; done; echo "every command has --help"
	@mandoc -T lint $(MANPAGE) 2>/dev/null | grep -v STYLE || true
	@echo "check OK"

install: app
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@pkill -x PowerMonitor 2>/dev/null || true
	@sleep 1
	@# remove earlier installs in the wrong places
	@rm -rf "$(HOME)/Applications/$(APP_NAME).app" "$(HOME)/Applications/PowerMonitor.app"
	@rm -f "$(BIN_DIR)/mon"
	rm -rf "$(APPS_DIR)/$(APP_NAME).app"
	ditto $(APP) "$(APPS_DIR)/$(APP_NAME).app"
	@mkdir -p "$(BIN_DIR)" "$(MAN_DIR)"
	ln -sf "$(APPS_DIR)/$(APP_NAME).app/Contents/Helpers/forkcast" "$(BIN_DIR)/forkcast"
	ln -sf "$(APPS_DIR)/$(APP_NAME).app/Contents/Resources/forkcast.1" "$(MAN_DIR)/forkcast.1"
	open "$(APPS_DIR)/$(APP_NAME).app"
	@echo "Installed $(APPS_DIR)/$(APP_NAME).app"
	@echo "CLI: $(BIN_DIR)/forkcast   ·   docs: forkcast help · man forkcast"

uninstall:
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "$(APPS_DIR)/$(APP_NAME).app"
	rm -f "$(BIN_DIR)/forkcast" "$(MAN_DIR)/forkcast.1"
	@echo "Removed. Your history and settings are still in '$(DATA_DIR)' (delete that folder to remove them)."

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open -n $(APP) --args --window

open:
	open -a "$(APPS_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build build
