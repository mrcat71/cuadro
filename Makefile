# Cuadro build helpers. `make app` produces build/Cuadro.app, `make dist` packages it and
# `make appcast` writes the Sparkle update feed for the packaged zip.

APP_NAME      := Cuadro
CONFIG        ?= release
VERSION       ?= 0.1.1
BUILD_NUMBER  ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ARCH          ?= $(shell uname -m)
BUILD_DIR     := build
APP           := $(BUILD_DIR)/$(APP_NAME).app
ICONSET       := $(BUILD_DIR)/AppIcon.iconset
ICNS          := $(BUILD_DIR)/AppIcon.icns
DIST_DIR      := $(BUILD_DIR)/dist
DIST_NAME      = cuadro-$(VERSION)-macos-$(ARCH)
BIN_DIR        = $(shell swift build -c $(CONFIG) --show-bin-path)
FRAMEWORK     := $(APP)/Contents/Frameworks/Sparkle.framework
# Sparkle's tools come with its Swift package (`swift package resolve` downloads them).
SPARKLE_BIN   := .build/artifacts/sparkle/Sparkle/bin
REPO_URL      := https://github.com/mrcat71/cuadro
# Lays out the disk image (app, Applications link, arrow): `pipx install dmgbuild`.
DMGBUILD      ?= dmgbuild

# Sign with the first "Apple Development" identity so the Screen Recording grant
# survives rebuilds; fall back to ad-hoc signing. Override with SIGN_IDENTITY=...
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $$2; exit }')
ifeq ($(strip $(SIGN_IDENTITY)),)
  SIGN_IDENTITY := -
endif
# Notarization needs a secure timestamp: CODESIGN_TIMESTAMP=--timestamp
CODESIGN_TIMESTAMP ?= --timestamp=none
SIGN = codesign --force --options runtime $(CODESIGN_TIMESTAMP) --sign "$(SIGN_IDENTITY)"
# An ad-hoc signature has no team ID, so the hardened runtime's library validation refuses to
# load Sparkle ("different Team IDs"). A real identity signs app and framework with one team.
ifeq ($(SIGN_IDENTITY),-)
  APP_ENTITLEMENTS := --entitlements Resources/AdHoc.entitlements
endif

.PHONY: all build test app run install notarize dist appcast clean

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
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks"
	cp "$(BIN_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/$(APP_NAME)"
	# Keeps the framework's symlinks; Sparkle's XPC services only serve sandboxed apps.
	rsync -a --delete --exclude XPCServices "$(BIN_DIR)/Sparkle.framework/" "$(FRAMEWORK)/"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"
	cp $(ICNS) "$(APP)/Contents/Resources/AppIcon.icns"
	# Inside out: Sparkle's helpers, the framework, then the app.
	$(SIGN) "$(FRAMEWORK)/Versions/B/Autoupdate"
	$(SIGN) "$(FRAMEWORK)/Versions/B/Updater.app"
	$(SIGN) "$(FRAMEWORK)"
	$(SIGN) $(APP_ENTITLEMENTS) "$(APP)"
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

# Packages the existing bundle as a zip (also the Sparkle update archive) and a disk image that
# opens on the app and an Applications link, with SHA256SUMS in build/dist. It does not
# rebuild, so a stapled ticket survives.
dist:
	@test -d "$(APP)" || { echo "error: $(APP) not found, run 'make app' first" >&2; exit 1; }
	mkdir -p "$(DIST_DIR)"
	ditto -c -k --norsrc --noextattr --noacl --keepParent "$(APP)" "$(DIST_DIR)/$(DIST_NAME).zip"
	rm -f "$(DIST_DIR)/$(DIST_NAME).dmg"
	$(DMGBUILD) -s Resources/dmg-settings.py -D app="$(APP)" "$(APP_NAME)" "$(DIST_DIR)/$(DIST_NAME).dmg"
	cd "$(DIST_DIR)" && shasum -a 256 "$(DIST_NAME).zip" "$(DIST_NAME).dmg" > SHA256SUMS
	@cat "$(DIST_DIR)/SHA256SUMS"

APPCAST_FLAGS = --download-url-prefix "$(REPO_URL)/releases/download/v$(VERSION)/" \
	--full-release-notes-url "$(REPO_URL)/releases" --link "$(REPO_URL)" \
	--embed-release-notes --maximum-deltas 0

# Signs the zip and writes build/dist/appcast.xml, the feed installed copies read from the
# latest release. The EdDSA key comes from SPARKLE_PRIVATE_KEY (CI), else from the login
# keychain (generate_keys). build/dist/$(DIST_NAME).md, when present, becomes the release notes
# in the update window. The check fails unless the feed offers this zip, signed for the
# SUPublicEDKey the app ships with.
appcast:
	@test -f "$(DIST_DIR)/$(DIST_NAME).zip" || { echo "error: $(DIST_DIR)/$(DIST_NAME).zip not found, run 'make dist' first" >&2; exit 1; }
	staging="$$(mktemp -d)" && \
		cp "$(DIST_DIR)/$(DIST_NAME).zip" "$$staging/" && \
		if [ -f "$(DIST_DIR)/$(DIST_NAME).md" ]; then cp "$(DIST_DIR)/$(DIST_NAME).md" "$$staging/"; fi && \
		if [ -n "$$SPARKLE_PRIVATE_KEY" ]; then \
			printf '%s' "$$SPARKLE_PRIVATE_KEY" | "$(SPARKLE_BIN)/generate_appcast" --ed-key-file - $(APPCAST_FLAGS) -o "$(DIST_DIR)/appcast.xml" "$$staging"; \
		else \
			"$(SPARKLE_BIN)/generate_appcast" $(APPCAST_FLAGS) -o "$(DIST_DIR)/appcast.xml" "$$staging"; \
		fi; \
		status=$$?; rm -rf "$$staging"; exit $$status
	swift Scripts/check-appcast.swift "$(DIST_DIR)/appcast.xml" "$(DIST_DIR)/$(DIST_NAME).zip" "$(APP)/Contents/Info.plist"

clean:
	rm -rf .build $(BUILD_DIR)
