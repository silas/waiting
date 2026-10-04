# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

"Waiting" is a macOS menu bar app (SwiftUI `MenuBarExtra`; icon is the `MenuBarIcon` template SVG in `Mac/Assets.xcassets`). The app icon (Finder, Settings, update dialogs) is the Icon Composer file `Mac/AppIcon.icon`: the same glyph, white on `#0d1117` like the website's `logo.svg`. It has no Dock icon or main window (`LSUIElement = YES`). Bundle ID: `dev.waiting.mac`.

## Build & run

There is a single Xcode project `mac.xcodeproj` with two targets: `Mac` (the menu bar app, product `Waiting.app`) and `waiting` (a command-line tool). Building the `Mac` scheme also builds `waiting` and embeds it at `Waiting.app/Contents/Helpers/waiting`. It lives in `Helpers`, not `MacOS`, because on a case-insensitive filesystem it would collide with the app executable `Waiting`. There is no test target. The only Swift package is Sparkle (`Mac` target only; `Package.resolved` is in `mac.xcodeproj/project.xcworkspace`).

```sh
# Build (output goes to ./build, which is gitignored)
xcodebuild -project mac.xcodeproj -scheme Mac -configuration Debug -derivedDataPath build build

# Run the built app (appears in the menu bar, not the Dock)
open build/Build/Products/Debug/Waiting.app

# Install the Claude Code hooks (points them at this build's CLI)
build/Build/Products/Debug/Waiting.app/Contents/Helpers/waiting setup claude

# Install the VS Code extension (needed for VS Code terminal focus)
build/Build/Products/Debug/Waiting.app/Contents/Helpers/waiting setup vscode

# Simulate a Claude Code hook event (the CLI reads hook JSON on stdin)
echo '{"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/demo"}' \
  | build/Build/Products/Debug/Waiting.app/Contents/Helpers/waiting hook claude
```

## Agent hooks → app

- The CLI dispatches commands in `CLI/main.swift`. `waiting hook claude` (`CLI/Hook.swift`) is meant to be run as a Claude Code hook command. Other harnesses (Codex, etc.) will get their own `waiting hook <agent>` subcommands. Each one maps its harness's native input to a harness-neutral `AgentEvent` (`Shared/AgentEvent.swift`) and posts it as a `DistributedNotificationCenter` notification (`dev.waiting.mac.agent-event`). The app never sees harness-specific event names.
- `waiting setup claude` (`CLI/Setup.swift`, `CLI/ClaudeSetup.swift`) installs a `<this executable's path> hook claude` command hook for each event in `claudeHookEvents` (`CLI/Claude.swift`). It writes to `$CLAUDE_CONFIG_DIR/settings.json`, falling back to `~/.claude/settings.json`.
  - It replaces any existing hook that runs a copy of `waiting` for Claude, so rerunning it after moving the app just updates the path. Other hooks are left alone.
  - It writes `settings.json.bak` first, and writes nothing if the hooks are already installed.
  - It rewrites the file with `JSONSerialization`, so keys end up sorted.
- `AgentEvent` carries a `SessionState`, generic fields (`cwd`, `message`, `terminal`), and a per-harness field for extras (`claude: ClaudeDetails`). Keep harness-specific data in that field.
- The Claude mapping lives in `CLI/Claude.swift`:
  - `Stop`/`Notification` → needs input, except `Notification` with `notification_type` `idle_prompt` (the reminder sent about 60s after `Stop`), which is dropped so it doesn't re-badge a session the user has already seen
  - `UserPromptSubmit`/`PreToolUse`/`PostToolUse` → working
  - `SessionStart` → idle, except with `source` `compact`, which is dropped because auto-compaction can happen mid-turn
  - `PreCompact` with `trigger` `manual` (the user ran `/compact`) → idle; auto compaction is dropped
  - `SessionEnd` → ended (the app removes the session)
  - Anything else is dropped and never posted.
- The payload is JSON in the notification's `object` string, because `userInfo` is dropped for sandboxed receivers.
- `Shared/` is compiled into both targets, so it holds the single definition of the wire format.
- `Mac/SessionStore.swift` keeps one `Session` per `"<agent>:<session_id>"`. Events older than the session's `lastUpdated` are ignored. Each hook is a separate CLI process, so events can arrive out of order: events sent before a session ended are also ignored for 60s after the end (`SessionStore.ended`), so they can't bring it back.
- `AgentEvent.process` identifies the agent's own process by PID and start time (`Shared/ProcessTable.swift`). The CLI takes it from the nearest ancestor that isn't a shell (`CLI/AgentProcessDetection.swift`). On launch and every 15s, the app drops sessions whose process has exited, which covers agents that crashed or were killed without sending an end event.
- State is saved on quit (`~/Library/Application Support/dev.waiting.mac/sessions.json`) and restored only if the app relaunches within 2 minutes, as after a Sparkle update. Otherwise it starts empty, since events sent while it wasn't running are lost. After a crash nothing is saved.
- A new session ID from the same agent process (`/clear`, `/resume`) replaces the old one, in case the old ID's end event was lost.

## Terminal focus

- The menu bar icon switches to `MenuBarIconAttention` when any session needs input (`SessionStore.waitingCount`). A needs-input session is marked seen (back to idle, until its next event) when its tab becomes focused, when an event arrives while its tab is already focused, or when it's clicked in the menu (`SessionStore.markFocusedSeen`, driven by `FocusMonitor.onChange`).
- The CLI captures where it runs as a `TerminalLocation` (`Shared/TerminalLocation.swift`, detection in `Shared/TerminalDetection.swift`, which the app also uses on tmux clients):
  - The bundle ID comes from `__CFBundleIdentifier`, then the `TERM_PROGRAM` table, then the first ancestor process that is an app.
  - The tty is the controlling terminal of the nearest ancestor process.
  - It also keeps an allowlist of terminal env vars.
  - It records raw identifiers and doesn't interpret them.
- `Mac/FocusMonitor.swift` watches the frontmost app. While that app has a `TerminalAdapter` (`Mac/Terminals/`), it polls `focusedTabKey()` once a second, because tab switches post no notification.
- All adapters use AppleScript. This triggers a one-time Automation permission prompt per terminal. If the permission is denied, no tab is ever considered focused.
  - iTerm2 and Terminal.app key tabs by tty.
  - VS Code and its forks (Insiders, Cursor, VSCodium) can't be scripted, so they need the companion extension instead (see below).
  - Ghostty (1.3+) keys terminals (panes) by their scripting `id`. It doesn't expose a tty or tell shells their ID, so the app learns it into `Session.learnedTabKey` (`TerminalAdapter.learnTabKey`). When a new session starts idle, or a session moves into working from another state, the user just typed in it, so if Ghostty is frontmost the focused terminal is the session's. Otherwise, on any event or when shown, it uses the only terminal whose `working directory` is the session's cwd, if exactly one matches. The learned key is stored with the terminal it was learned in (`Session.learnedTab`) and only used while that's still the terminal, so a changed `TerminalLocation`, or for tmux a client in a different terminal, means relearning.
- VS Code (`Mac/Terminals/VSCodeAdapter.swift`, one instance per editor, told apart by URL scheme) keys terminals by tty. The extension lives in `VSCode/` (plain JS, no build step):
  - Each window writes `~/Library/Application Support/dev.waiting.mac/vscode/<scheme>-<extension host pid>.json` with its focus state, its terminals' shell PIDs and the active one. The app maps shell PIDs to ttys with `ProcessTable.tty`, and deletes files whose extension host has exited.
  - The file also holds `showURI` from `vscode.env.asExternalUri`, which carries the window's `windowId`. Opening it with `pid=<shell pid>` added makes VS Code route it to that window's URI handler, which shows the terminal, and focus the window.
  - With no state files (extension missing or editor not running), `selectTab` returns `.failed`, so the editor is just activated.
  - The `Mac` target's "Package VS Code Extension" Run Script phase zips `VSCode/` into `Waiting.app/Contents/Resources/waiting.vsix`. When adding a file to the extension, add it to that phase's input paths and zip command. The install logic is in `Shared/VSCodeExtension.swift`. It installs the vsix with each installed editor's bundled CLI (`--install-extension`).
  - Users install it from the Integrations tab of Settings (`Mac/VSCodeExtensionStatus.swift`), or with `waiting setup vscode` (`CLI/VSCodeSetup.swift`).
  - On launch, the app updates the extension in editors where an older version is installed (`VSCodeExtensionStatus.updateInstalled`). It never installs into an editor that doesn't already have it.
  - Updates are detected by version, so bump `version` in both `VSCode/extension/package.json` and `VSCode/extension.vsixmanifest` whenever the extension changes.
- tmux (`Mac/Terminals/Tmux.swift`) isn't a `TerminalAdapter` but a layer on top of them. Inside tmux, the CLI's tty is the pane's and its bundle ID is whatever terminal started the tmux server, so the app ignores those:
  - A session is identified by its pane (`TMUX` and `TMUX_PANE` from `TerminalLocation.environment`; the CLI doesn't change).
  - The outer terminal is resolved live from the tmux client best placed to show the pane: the client's environment is read with `ProcessTable.environment` (`KERN_PROCARGS2`) and run through `TerminalLocation.detect(pid:environment:)`, with the client's tty as the tab key. So detach and reattach elsewhere just works, under any adapter.
  - tmux is run as the server's own executable (`ProcessTable.executablePath` of the PID in `TMUX`), since the app's PATH may not include it. Each call has a 1s timeout because it runs on the main actor.
  - Showing a session runs `switch-client`/`select-window`/`select-pane` in that client, then selects the client's tab. A session whose pane or server is gone is removed. One whose pane can't be shown (no client attached, its terminal can't be detected, or tmux didn't answer) is kept, and the terminal that started the tmux server is activated if it's running.
  - `FocusMonitor` also records which panes are current in clients of the frontmost terminal (`Focus.tmuxViews`), so switching tmux windows counts as a focus change. It only queries servers that some session is in (`tmuxServers`).
  - For tmux sessions, `learnTabKey` only runs when the user is known to be there.
  - Nested tmux, tmux over SSH and Zellij aren't supported.
- The menu lists needs-input sessions first, longest-waiting first, then the rest, most recent first (`SessionStore.sorted`). The first ten items get ⌘1…⌘9, ⌘0.
- Holding ⌥ turns each item into "Remove <name>" (with ⌥⌘1…⌥⌘0), using SwiftUI `modifierKeyAlternate`. "Clear Idle Sessions" removes every idle session.
- Clicking a session in the menu marks it seen and calls `TerminalAdapters.show`, which uses the adapter's `selectTab` to select the tab and raise its window, then activates the terminal app. Terminals without an adapter are just activated. If the tab or the terminal app is gone (or the session has no terminal info), the session is removed instead; for tmux sessions, only if the pane is gone.
- To add a terminal: write a `TerminalAdapter` (`tabKey(for:)`, `focusedTabKey()`, `selectTab(_:)`, and `learnTabKey(for:userIsHere:)` if tabs can't be identified from what the CLI captures), register it in `TerminalAdapters.all`, and add any env var it needs to `TerminalLocation.environmentKeys`.
- Optional attention effects, all off by default, are toggled in the Alerts tab of Settings and persisted by `Mac/Attention/AttentionSettings.swift` (`attention.<name>` in UserDefaults):
  - The count shows the number of waiting sessions next to the plain icon, in place of the badge.
  - The pulse and the screen-edge glow play once, from `SessionStore.onStartWaiting`, when a session moves into needs-input and isn't in the focused tab. The pulse animates the status item button's layer (`MenuBarList.pulse`), because SwiftUI doesn't animate `MenuBarExtra` labels. The glow (`ScreenEdgeGlow`) is a click-through panel along the top of the screen the pointer is on. Its color is System Accent (amber when the accent is graphite), Amber, Purple or a custom sRGB color; Settings flashes a preview when it's turned on or recolored, live while a custom color is being picked, and likewise pulses the icon when the pulse is turned on and shows a sample count of 1 for 2s when the count is turned on with nothing waiting (`AttentionSettings.previewCount`).

## Global shortcuts & settings

- The menu has a "Settings…" item that opens the SwiftUI `Settings` scene (`Mac/SettingsView.swift`), which has General (global shortcuts, updates), Alerts and Integrations (VS Code extension) tabs. The app has no Dock icon, so it calls `NSApp.activate()` first, or the window would open behind the frontmost app.
- Global shortcuts live in `Mac/Shortcuts/`:
  - `HotKeys` wraps Carbon `RegisterEventHotKey`, which needs no permissions.
  - `ShortcutAction` lists the bindable actions with their titles and defaults.
  - `ShortcutSettings` persists bindings to UserDefaults (`shortcut.<action>`; a missing key means the default, JSON `null` means cleared) and keeps them registered. It records which actions failed to register (`unavailable`) and suspends all hot keys while one is being recorded.
  - `ShortcutRecorder` captures the next keyDown with a local `NSEvent` monitor. Esc cancels. A shortcut must include ⌃, ⌥ or ⌘ unless it's a function key.
- The actions are performed in `WaitingApp.init`:
  - "Jump to waiting or next session" (default ⌃⌥⌘L) calls `SessionStore.showNext`.
    - If any session needs input, it shows the longest-waiting one, which is the top of `sorted`.
    - Otherwise it cycles in menu order: it shows the next session after the one in the focused tab that's in a different tab (wrapping around). If no tab can be identified (no adapter, or Automation denied), it continues from the last session it showed while that session's terminal is frontmost; otherwise it shows the first session.
    - A session whose tab is gone is removed and the next one is tried.
  - "Open menu" (default ⌃⌥⌘O) calls `MenuBarList.open`. SwiftUI can't open a `MenuBarExtra`, so this clicks the `NSStatusBarButton` in the app's `NSStatusBarWindow`.
- To add an action: add a case to `ShortcutAction` and handle it in `WaitingApp.init`.

## Project structure & settings

- App sources live in `Mac/`, CLI sources in `CLI/`, and code compiled into both in `Shared/`. All are file-system-synchronized groups: new files are picked up automatically, so there's no need to edit `project.pbxproj` to add sources.
- Most Info.plist values are set via `INFOPLIST_KEY_*` build settings in `project.pbxproj`. Keys Xcode doesn't know (Sparkle's `SU*`) go in `Mac/Info.plist`, which is merged into the generated one and excluded from the `Mac` group's resources by an exception set.
- Entry point is `Mac/WaitingApp.swift` (`@main struct WaitingApp`).
- Build settings worth knowing:
  - Deployment target is macOS 27.0.
  - The App Sandbox is disabled (it would block the AppleScript focus queries). Hardened Runtime is on for both targets (required for notarization); the app's `Mac/Waiting.entitlements` has `com.apple.security.automation.apple-events`.
  - `NSAppleEventsUsageDescription` is set via `INFOPLIST_KEY_NSAppleEventsUsageDescription`.
  - Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Code is MainActor-isolated by default, so mark background work `nonisolated` or `@concurrent` explicitly.

## Updates & releases

- Sparkle 2 is wrapped by `Mac/Updater.swift` (`SPUStandardUpdaterController`). The menu has "Check for Updates…" and the General tab of Settings has an "Updates" section (automatic checks toggle, version, Check Now). It opts into gentle scheduled update reminders since the app has no Dock icon.
- `Mac/Info.plist` holds `SUFeedURL` (`https://releases.waiting.dev/appcast.xml`), `SUPublicEDKey` and `SUEnableAutomaticChecks`. The EdDSA private key lives in the release machine's login Keychain (created with Sparkle's `generate_keys`).
- Sparkle replaces the bundle in place, so the CLI path in Claude's `settings.json` stays valid across updates.
- `scripts/release.sh` archives, exports with Developer ID (`scripts/ExportOptions.plist`), notarizes (`NOTARY_PROFILE`, default `waiting-notary`), staples, zips into `UPDATES_DIR` and runs `generate_appcast`. `UPDATES_DIR` must persist every past zip plus `appcast.xml`. It also builds a signed, notarized `build/release/Waiting.dmg` for the website, kept out of `UPDATES_DIR` because `generate_appcast` would treat it as an update. `make upload` copies both to the R2 bucket behind `https://releases.waiting.dev/` with rclone (the DMG as the fixed `Waiting.dmg`, `appcast.xml` last).
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (both Mac configurations) for every release; Sparkle compares `CFBundleVersion`. Sparkle's tools are at `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build.
