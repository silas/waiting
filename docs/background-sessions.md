# Answering background sessions from Waiting

Status: idea, not implemented. Findings from 2026-10-06.

## Goal

When a background session (Claude Code `claude --bg` or ←, or a Codex session in the shared app server) needs input, Waiting opens a small floating terminal attached to it. The user answers, and the terminal detaches and closes, including when the user just clicks away.

## Terminal view

| | Installed | Download |
|---|---|---|
| Waiting today (Release, arm64) | 5.6 MB | 3.2 MB (DMG) |
| libghostty (Ghostty 1.3.1's arm64 binary, as an upper bound) | +16–20 MB | +5–7 MB |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | +1–2 MB | less |

- libghostty: GPU-rendered and the best match for Claude's and Codex's terminal UIs. But its embedding API (`ghostty.h`) isn't public or stable, building it needs Zig (`zig build -Demit-xcframework`) before the Xcode build, and a universal build would double its size. The size above includes Ghostty's own Swift UI and its built-in fonts (about 4.6 MB of constant data).
- SwiftTerm: pure Swift, added with SwiftPM like Sparkle, stable API, CPU rendering.
- Memory: nothing while Waiting isn't running. While it is, unused library code costs almost nothing if the terminal library is only started when a terminal first opens. Each open terminal is probably tens of MB (renderer, glyph cache, scrollback, the attach process); this wasn't measured.
- Plan: prototype with SwiftTerm and only move to libghostty if its rendering isn't good enough.

## Attaching and detaching

### Claude Code (2.1.292, from `claude attach --help`; not tested)

- Run `claude attach <job ID>` directly as the terminal's command, with no shell. `ClaudeAttach.backgroundJobID` already finds the job ID.
- The session runs in `claude daemon` on its own pty, and `attach` only shows it ("The session keeps running either way" after ← or Ctrl+Z). Detaching is closing the terminal, which kills the `attach` process, the same as closing a terminal tab.

### Codex (CLI 0.160.0, app server 0.160.1; tested)

- Attach with `codex resume <session ID>`. It connects to the shared `codex app-server --managed-daemon`, and detaching is closing the terminal.
- **A pending approval survives the terminal UI going away.** The terminal UI was hung up (pty closed, SIGHUP) while "Would you like to run the following command?" was showing. After `codex resume <id>` the same approval was shown again, and answering `y` ran the command.
- **A turn keeps running with no terminal UI.** The terminal UI was hung up 3s into `sleep 40 && touch done.txt`. The file appeared 37s later and the session log recorded `task_complete`.
- `codex resume` may first show a full-screen "Update available" choice ("1. Update now / 2. Skip / 3. Skip until next version"), before the session. Esc skips it, but don't send Esc blindly: when the update notice is only a banner, Esc interrupts the turn.
- `codex queue --thread <id> --message <text>` can send a text reply without a terminal, but can't answer an approval.

## Things Waiting would have to handle

- Waiting becomes a terminal. Hooks from a session attached in the panel find that `attach` (or `codex resume`) process, so they'd record Waiting itself as the session's terminal (`ClaudeAttach.clientLocation`, `CodexClient`). Mark the panel's processes (an env var) and skip or special-case them.
- Click-away: use a non-activating `NSPanel` and detach when it stops being key. Wait a few seconds before closing, so clicking straight back doesn't re-attach.
- Anything typed but not submitted is lost on detach.
- Run the attach command with the user's login environment (PATH, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`); `Shared/LoginShell.swift` already gets it.
- If it ships, turn the two Codex results into `make e2e-live` tests, so a Codex release that changes this behavior fails a test.

## Repeating the Codex tests

Drive the `codex` terminal UI in a pty (Python's `pty.fork`, 120x40, answering `ESC[6n` cursor queries). Strip ANSI codes and whitespace before matching text, since the UI moves the cursor instead of printing spaces.

- Approval: in a fresh git repo, `codex -a on-request -s read-only "Run the shell command: touch approved.txt (it needs approval, request it)"`. (`approval_policy = "untrusted"` is no longer accepted.) Press Enter at "Trust this folder?". Wait for "Would you like to run", then close the pty and SIGHUP the process. Then run `codex resume <id>`.
- Mid-turn: `codex -a never -s workspace-write "Run this exact shell command and nothing else: sleep 40 && touch done.txt"`. The terminal UI doesn't reliably show the command while it runs, so watch the session's log (`~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`, first line `session_meta` with `cwd`) for a `custom_tool_call` containing the command, and hang up a few seconds after.
- The session ID is the `id` in that log's `session_meta`.
- Cleanup: `codex delete --force <id>` (it won't confirm without a terminal otherwise), and remove the `[projects."<test dir>"] trust_level = "trusted"` entries the trust prompt adds to `~/.codex/config.toml`.
