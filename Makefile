# OpenBattery — build, sign and install from the command line.
PROJECT      := OpenBattery.xcodeproj
SCHEME       := OpenBattery
# Release-Direct by default: the build people download and run, and the only one
# that can read a connected iPhone. Pass CONFIG=Release for the sandboxed App
# Store shape.
CONFIG       ?= Release-Direct
BUILD_DIR    := build
# A derived data path rather than SYMROOT: overriding SYMROOT leaves the Swift
# package targets unable to find each other's modules ("Unable to resolve module
# dependency: 'SwiftASN1'"), and the device code depends on nothing but packages.
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/OpenBattery.app
INSTALL_DIR  ?= /Applications
# Extra settings passed to xcodebuild, e.g. CODE_SIGNING_ALLOWED=NO on CI where
# no signing certificate exists.
XCODEBUILD_FLAGS ?=

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
		-derivedDataPath $(DERIVED_DATA) $(XCODEBUILD_FLAGS) build

## Run the unit tests
test: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) $(XCODEBUILD_FLAGS) test

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
