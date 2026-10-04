import Foundation

extension AgentHooks {
  /// Claude Code's hooks, in `settings.json` in `$CLAUDE_CONFIG_DIR` or `~/.claude`.
  nonisolated static let claude = AgentHooks(
    agent: "claude",
    name: "Claude Code",
    configVariable: "CLAUDE_CONFIG_DIR",
    defaultConfigDirectory: ".claude",
    hooksFile: "settings.json",
    // Keep in sync with the mapping in `CLI/Claude.swift`.
    events: [
      "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
      "PreCompact", "SessionEnd",
    ],
    isAgentProcess: isClaude
  )

  /// Whether a command line runs Claude Code: the native binary (whose process name is its version,
  /// so only `argv[0]` says `claude`) or the npm package under Node.
  nonisolated private static func isClaude(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return first.split(separator: "/").last == "claude"
      || arguments.dropFirst().first?.contains("/@anthropic-ai/claude-code/") == true
  }
}
