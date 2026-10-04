# CLT's swift-testing macro plugin isn't on the default path; full Xcode doesn't need this.
SWIFT_TEST_FLAGS := $(if $(findstring CommandLineTools,$(shell xcode-select -p)),-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)

.PHONY: web test perf app

# Full Xcode is required for xcodebuild; use it even when xcode-select still points at the Command Line Tools.
XCODE_DEV := $(if $(findstring CommandLineTools,$(shell xcode-select -p)),/Applications/Xcode.app/Contents/Developer,$(shell xcode-select -p))

web:
	[ -d Web/node_modules ] || (cd Web && npm ci)
	cd Web && node build.mjs

test:
	cd Web && npm test
	Scripts/check-web-drift.sh
	Scripts/check-module-boundaries.sh
	Scripts/check-localization.py
	Scripts/test-scroll-sync.sh
	# Each swift test run leaves a dead Dock tile on macOS 27; clean up even when a test fails.
	status=0; for p in Packages/*/; do if [ -d "$$p/Tests" ]; then (cd "$$p" && swift test $(SWIFT_TEST_FLAGS)) || { status=1; break; }; fi; done; \
	  Scripts/clean-dock-ghosts.sh; exit $$status

# 1 MB-document performance tests (skipped by `make test`); the < 8 ms budget only applies to optimised builds.
perf:
	cd Packages/EditorKit && MD2_PERF=1 swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter PerformanceTests; \
	  status=$$?; ../../Scripts/clean-dock-ghosts.sh; exit $$status

app:
	DEVELOPER_DIR="$(XCODE_DEV)" xcodebuild -project MacDown2.xcodeproj -scheme MacDown2 -configuration Debug -derivedDataPath build/DerivedData build
