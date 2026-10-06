# Cuadro build helpers. `make app` produces build/Cuadro.app, `make dist` packages it.

APP_NAME      := Cuadro
CONFIG        ?= release
VERSION       ?= 0.1.0
BUILD_NUMBER  ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ARCH          ?= $(shell uname -m)
BUILD_DIR     := build
APP           := $(BUILD_DIR)/$(APP_NAME).app
ICONSET       := $(BUILD_DIR)/AppIcon.iconset
ICNS          := $(BUILD_DIR)/AppIcon.icns
DIST_DIR      := $(BUILD_DIR)/dist
DIST_NAME      = cuadro-$(VERSION)-macos-$(ARCH)
BIN_DIR        = $(shell swift build -c $(CONFIG) --show-bin-path)

# Sign with the first "Apple Development" identity so the Screen Recording grant
# survives rebuilds; fall back to ad-hoc signing. Override with SIGN_IDENTITY=...
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $$2; exit }')
ifeq ($(strip $(SIGN_IDENTITY)),)
  SIGN_IDENTITY := -
endif
# Notarization needs a secure timestamp: CODESIGN_TIMESTAMP=--timestamp
CODESIGN_TIMESTAMP ?= --timestamp=none

.PHONY: all build test app run install notarize dist clean

all: app

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

test:
	swift test

$(ICNS): Sources/cuadro-icon/main.swift
	swift build -c $(CONFIG) --product cuadro-icon
	mkdir -p $(ICONSET)
	"$(BIN_DIR)/cuadro-icon" $(ICONSET)
	iconutil --convert icns --output $(ICNS) $(ICONSET)

app: build $(ICNS)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"
	cp $(ICNS) "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --options runtime $(CODESIGN_TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(APP)"
	@echo "Built $(APP) (signing identity: $(SIGN_IDENTITY))"

run: app
	-pkill -x $(APP_NAME)
	open "$(APP)"

install: app
	ditto "$(APP)" "$(HOME)/Applications/$(APP_NAME).app"

# Notarizes the existing bundle and staples the ticket. Needs a Developer ID
# Application signature made with CODESIGN_TIMESTAMP=--timestamp, and the
# NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD (app-specific password)
# environment variables.
notarize:
	@test -d "$(APP)" || { echo "error: $(APP) not found, run 'make app' first" >&2; exit 1; }
	ditto -c -k --keepParent "$(APP)" "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME)-notarize.zip" --apple-id "$$NOTARY_APPLE_ID" --team-id "$$NOTARY_TEAM_ID" --password "$$NOTARY_PASSWORD" --wait
	xcrun stapler staple "$(APP)"
	rm -f "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"

# Packages the existing bundle as a zip and a drag-to-Applications dmg with
# SHA256SUMS in build/dist. It does not rebuild, so a stapled ticket survives.
dist:
	@test -d "$(APP)" || { echo "error: $(APP) not found, run 'make app' first" >&2; exit 1; }
	mkdir -p "$(DIST_DIR)"
	ditto -c -k --norsrc --noextattr --noacl --keepParent "$(APP)" "$(DIST_DIR)/$(DIST_NAME).zip"
	staging="$$(mktemp -d)" && \
		ditto "$(APP)" "$$staging/$(APP_NAME).app" && \
		ln -s /Applications "$$staging/Applications" && \
		hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$$staging" -ov -format UDZO "$(DIST_DIR)/$(DIST_NAME).dmg"; \
		status=$$?; rm -rf "$$staging"; exit $$status
	cd "$(DIST_DIR)" && shasum -a 256 "$(DIST_NAME).zip" "$(DIST_NAME).dmg" > SHA256SUMS
	@cat "$(DIST_DIR)/SHA256SUMS"

clean:
	rm -rf .build $(BUILD_DIR)
