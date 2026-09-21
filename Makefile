SHELL := /bin/zsh

PROJECT := TinyUsage.xcodeproj
SIMULATOR_DESTINATION ?= generic/platform=iOS Simulator
TEST_SIMULATOR_DESTINATION ?= platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5
MAC_DESTINATION ?= platform=macOS

.PHONY: bootstrap generate generate-check format format-check test build clean

bootstrap:
	@command -v xcodegen >/dev/null || (echo "Install XcodeGen: brew install xcodegen"; exit 1)
	@xcodegen generate
	@echo "TinyUsage is ready. Copy Config/Developer.example.xcconfig for a physical-device build."

generate:
	xcodegen generate

generate-check:
	@scripts/check-generated-project.sh $(PROJECT)

format:
	@files=$$(find TinyUsage TinyUsageCollector TinyUsageCollectorCore TinyUsageDomain TinyUsageWidget TinyUsageTests TinyUsageCollectorTests -name '*.swift' -print); xcrun swift-format format --in-place $$files

format-check:
	@files=$$(find TinyUsage TinyUsageCollector TinyUsageCollectorCore TinyUsageDomain TinyUsageWidget TinyUsageTests TinyUsageCollectorTests -name '*.swift' -print); xcrun swift-format lint --strict $$files

test:
	swift test --package-path TinyUsageDomain
	xcodebuild test -project $(PROJECT) -scheme TinyUsageCollector -destination '$(MAC_DESTINATION)' CODE_SIGNING_ALLOWED=NO
	xcodebuild test -project $(PROJECT) -scheme TinyUsage -destination '$(TEST_SIMULATOR_DESTINATION)' CODE_SIGNING_ALLOWED=NO

build:
	xcodebuild build -project $(PROJECT) -scheme TinyUsageCollector -destination '$(MAC_DESTINATION)' CODE_SIGNING_ALLOWED=NO
	xcodebuild build -project $(PROJECT) -scheme TinyUsage -destination '$(SIMULATOR_DESTINATION)' CODE_SIGNING_ALLOWED=NO

clean:
	xcodebuild clean -project $(PROJECT) -scheme TinyUsage CODE_SIGNING_ALLOWED=NO
