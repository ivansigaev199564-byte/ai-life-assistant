# Команды выполняются на macOS. На Windows они нужны только как справка.

PROJECT = AILifeAssistant.xcodeproj
SCHEME  = AILifeAssistant
DEVICE ?= iPhone 17 Pro

.PHONY: generate build test clean open lint

generate:
	xcodegen generate --spec project.yml

build: generate
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(DEVICE)" CODE_SIGNING_ALLOWED=NO

test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(DEVICE)" CODE_SIGNING_ALLOWED=NO

open: generate
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) build DerivedData TestResults.xcresult
