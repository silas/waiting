CONFIG ?= Debug
SOURCES := Mac CLI Shared
APP := build/Build/Products/$(CONFIG)/Waiting.app
CLI := $(APP)/Contents/Helpers/waiting
# rclone remote for the R2 account (see `upload`)
R2_REMOTE ?= r2
# Disk image for the website's fixed download link, built by `release`
DMG := build/release/Waiting.dmg

.PHONY: help build run stop reset setup-claude setup-codex setup-vscode event format lint hooks release upload clean

help: ## List the targets
	@awk -F ':.*## ' '/^[a-z-]+:.*## / { printf "  %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Build Waiting.app and the CLI (CONFIG=Debug or Release)
	xcodebuild -project mac.xcodeproj -scheme Mac -configuration $(CONFIG) -derivedDataPath build build

run: build stop ## Build, quit any running copy and launch the app
	open $(APP)

stop: ## Quit the running app
	@pkill -x Waiting && while pgrep -x Waiting >/dev/null; do sleep 0.1; done || true

# By path: a stale ~/Library/Containers/dev.waiting.mac makes `defaults delete dev.waiting.mac`
# read the container's preferences instead. Application Support's vscode/ is the editor
# extension's state, so only the saved sessions go.
reset: stop ## Quit the app and delete its settings, saved sessions, caches and permission approvals (keeps agent hooks and editor extensions)
	-@defaults delete "$(HOME)/Library/Preferences/dev.waiting.mac.plist" 2>/dev/null
	rm -f "$(HOME)/Library/Application Support/dev.waiting.mac/sessions.json"
	rm -rf "$(HOME)/Library/Caches/dev.waiting.mac" "$(HOME)/Library/HTTPStorages/dev.waiting.mac"
	tccutil reset All dev.waiting.mac

setup-claude: build ## Install the Claude Code hooks, pointing at this build's CLI
	$(CLI) setup claude

setup-codex: build ## Install the Codex hooks, pointing at this build's CLI
	$(CLI) setup codex

setup-vscode: build ## Install the VS Code extension
	$(CLI) setup vscode

event: ## Send a test hook event (AGENT=claude or codex, EVENT=Stop, SESSION=s1, CWD=/tmp/demo)
	echo '{"session_id":"$(or $(SESSION),s1)","hook_event_name":"$(or $(EVENT),Stop)","cwd":"$(or $(CWD),/tmp/demo)"}' \
		| $(CLI) hook $(or $(AGENT),claude)

format: ## Format Swift sources in place
	xcrun swift-format format --in-place --recursive $(SOURCES)

lint: ## Check Swift formatting
	xcrun swift-format lint --strict --recursive $(SOURCES)

hooks: ## Install the git pre-commit hook in this checkout
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit

release: ## Build, notarize and publish a release into UPDATES_DIR (see scripts/release.sh)
	scripts/release.sh

upload: ## Upload $UPDATES_DIR and Waiting.dmg to the R2 bucket $R2_BUCKET with rclone, appcast.xml last
	@test -n "$(UPDATES_DIR)" || { echo "error: set UPDATES_DIR to the releases directory" >&2; exit 1; }
	@test -n "$(R2_BUCKET)" || { echo "error: set R2_BUCKET to the R2 bucket name" >&2; exit 1; }
	@test -f "$(UPDATES_DIR)/appcast.xml" || { echo "error: no appcast.xml in $(UPDATES_DIR)" >&2; exit 1; }
	@test -f "$(DMG)" || { echo "error: no $(DMG); run make release first" >&2; exit 1; }
	rclone copy "$(UPDATES_DIR)" "$(R2_REMOTE):$(R2_BUCKET)" --exclude appcast.xml --exclude .DS_Store --progress
	rclone copyto "$(DMG)" "$(R2_REMOTE):$(R2_BUCKET)/Waiting.dmg" \
		--header-upload "Cache-Control: no-cache"
	rclone copyto "$(UPDATES_DIR)/appcast.xml" "$(R2_REMOTE):$(R2_BUCKET)/appcast.xml" \
		--header-upload "Cache-Control: no-cache"

clean: ## Remove build output (keeps build/updates and Sparkle's tools in build/SourcePackages)
	find build -mindepth 1 -maxdepth 1 ! -name updates ! -name SourcePackages -exec rm -rf {} +
