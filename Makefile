SIM ?= iPhone 17 Pro
OS ?= 26.4
DESTINATION = platform=iOS Simulator,name=$(SIM),OS=$(OS)
XCODEBUILD = xcodebuild -project OpenMEAT.xcodeproj -scheme OpenMEAT -destination '$(DESTINATION)' \
	-derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
PACKAGE = Packages/OpenMEATKit

DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/(available \(paired\)|connected)/ && /iPhone/ && /physical/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$$/) {print $$i; exit}}')

.PHONY: device generate build test test-package test-unit test-integration test-app test-app-unit test-ui test-live clean

## Regenerate OpenMEAT.xcodeproj from project.yml (requires `brew install xcodegen`).
generate:
	xcodegen generate

build: generate
	$(XCODEBUILD) build

## Everything: package (unit + hermetic integration) + app unit + UI.
test: test-package test-app

## Package unit + integration tests on macOS (fast, no simulator).
test-package:
	swift test --package-path $(PACKAGE)

test-unit:
	swift test --package-path $(PACKAGE) --filter 'ThermoWorksCloudTests|CookCoreTests|CookSessionTests'

test-integration:
	swift test --package-path $(PACKAGE) --filter IntegrationTests

## Real ThermoWorks Cloud smoke test (read-only). Needs THERMOWORKS_EMAIL / THERMOWORKS_PASSWORD.
test-live:
	@test -n "$$THERMOWORKS_EMAIL" || (echo "Set THERMOWORKS_EMAIL and THERMOWORKS_PASSWORD" && exit 1)
	swift test --package-path $(PACKAGE) --filter LiveCloudSmokeTests

## App unit + UI tests on the simulator.
test-app: generate
	$(XCODEBUILD) test

test-app-unit: generate
	$(XCODEBUILD) test -only-testing:OpenMEATTests

test-ui: generate
	$(XCODEBUILD) test -only-testing:OpenMEATUITests

clean:
	rm -rf build $(PACKAGE)/.build

## Build, install and launch on a connected iPhone (needs Config/Signing.local.xcconfig).
device: generate
	@test -n "$(DEVICE)" || (echo "No paired iPhone found; pass DEVICE=<udid>" && exit 1)
	xcodebuild -project OpenMEAT.xcodeproj -scheme OpenMEAT -configuration Debug -destination 'id=$(DEVICE)' \
		-derivedDataPath build/DeviceData -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE) build/DeviceData/Build/Products/Debug-iphoneos/OpenMEAT.app
	xcrun devicectl device process launch --device $(DEVICE) $$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/DeviceData/Build/Products/Debug-iphoneos/OpenMEAT.app/Info.plist)
