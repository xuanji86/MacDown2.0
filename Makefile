# CLT's swift-testing macro plugin isn't on the default path; full Xcode doesn't need this.
SWIFT_TEST_FLAGS := $(if $(findstring CommandLineTools,$(shell xcode-select -p)),-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)

.PHONY: web test app

# Full Xcode is required for xcodebuild; use it even when xcode-select still points at the Command Line Tools.
XCODE_DEV := $(if $(findstring CommandLineTools,$(shell xcode-select -p)),/Applications/Xcode.app/Contents/Developer,$(shell xcode-select -p))

web:
	[ -d Web/node_modules ] || (cd Web && npm ci)
	cd Web && node build.mjs

test:
	cd Web && npm test
	Scripts/check-web-drift.sh
	Scripts/check-module-boundaries.sh
	for p in Packages/*/; do if [ -d "$$p/Tests" ]; then (cd "$$p" && swift test $(SWIFT_TEST_FLAGS)) || exit 1; fi; done

app:
	DEVELOPER_DIR=$(XCODE_DEV) xcodebuild -project MacDown2.xcodeproj -scheme MacDown2 -configuration Debug -derivedDataPath build/DerivedData build
