> [!WARNING]
> This project was 100% vibe coded. I have not reviewed the code, use at your own risk.
>
> I now use [Rex](https://www.superlogical.com/rex).

# Waiting

Know when your agents are waiting on you.

Waiting lives in your menu bar and keeps track of your Claude Code and Codex sessions. When one needs you, jump straight to its terminal tab.

## How it works

1. **Connect your agents.** Open Waiting's Settings to install the hooks, or run `waiting setup claude` or `waiting setup codex` in your terminal.
2. **Keep working.** Run your sessions across tabs, windows and tmux panes. Waiting keeps track of them, so you don't have to.
3. **Jump back in.** When a session needs you, the menu bar icon lights up. Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>L</kbd> to jump to the session that's been waiting longest.

## Features

- **Get a nudge, your way.** Choose a count or pulse on the menu bar icon, a popup, a sound, or a glow along the top of your screen. Each is off by default, and none will alert you about the tab you're already looking at.
- **One shortcut.** Press ⌃⌥⌘L to jump to the session that's been waiting longest. When no sessions need you, it cycles through them.
- **The exact tab.** Waiting brings you straight to the terminal tab where the session is running.
- **Clears itself.** Opening a session's tab clears its waiting status. Sessions that exit or crash disappear from the menu automatically.
- **Native and private.** A lightweight native Mac app. No account required, no telemetry, and your session data stays on your Mac.

## Works with your setup

- **Agents:** Claude Code, Codex
- **Terminals and editors:** Terminal, iTerm2, Ghostty, VS Code, Cursor, VSCodium, tmux

VS Code and its forks need Waiting's companion extension, which you can install from Settings or with `waiting setup vscode`.

## Building from source

Requires Xcode with the macOS 26 SDK.

```sh
make build          # Build Waiting.app and the CLI into ./build
make run            # Build, quit any running copy and launch the app
make setup-claude   # Point the Claude Code hooks at this build's CLI
make setup-codex    # Point the Codex hooks at this build's CLI
make test           # Run the unit tests
make help           # List all targets
```

See [CLAUDE.md](CLAUDE.md) for architecture notes.
