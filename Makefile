APP_NAME := Zhiyu Launch
CONFIG := release
BUILD_BIN := .build/$(CONFIG)/ZhiyuLaunch
APP_BUNDLE := build/$(APP_NAME).app

.PHONY: all build app run test clean install

all: app

## Compile the Swift package (release)
build:
	swift build -c $(CONFIG)

## Assemble the .app bundle and ad-hoc sign it
app: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BUILD_BIN)" "$(APP_BUNDLE)/Contents/MacOS/ZhiyuLaunch"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	codesign --force --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

## Build and launch the app bundle
run: app
	open "$(APP_BUNDLE)"

## Run unit tests
test:
	swift test

## Install into /Applications (recommended for launch-at-login)
install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Installed /Applications/$(APP_NAME).app"

clean:
	rm -rf .build build
