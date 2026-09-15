# OpenBattery — build, sign and install from the command line.
PROJECT      := OpenBattery.xcodeproj
SCHEME       := OpenBattery
CONFIG       ?= Release
BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(CONFIG)/OpenBattery.app
INSTALL_DIR  ?= /Applications

.PHONY: all project build test run install uninstall clean

all: build

## Regenerate the Xcode project from project.yml
project:
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

## Build and sign the app
build: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		SYMROOT=$(BUILD_DIR) build

## Run the unit tests
test: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		SYMROOT=$(BUILD_DIR) test

## Build, then (re)launch the menu bar app
run: build
	-killall OpenBattery 2>/dev/null || true
	open $(APP)

## Copy the app to /Applications (a stable path keeps Login Items happy)
install: build
	-killall OpenBattery 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/OpenBattery.app
	cp -R $(APP) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/OpenBattery.app

## Remove the app
uninstall:
	-killall OpenBattery 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/OpenBattery.app

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)
