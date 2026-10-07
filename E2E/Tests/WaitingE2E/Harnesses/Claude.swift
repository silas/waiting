import Foundation

struct ClaudeHarness: Harness {
  let agent = "claude"
  let configVariable = "CLAUDE_CONFIG_DIR"
  let hooksFile = "settings.json"
  let hookEvents = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
    "PreCompact", "SessionEnd",
  ]
  let executable = "claude"
  var description: String { "Claude Code" }

  func input(for moment: Moment, sessionID: String, cwd: String) -> [String: Any]? {
    var input: [String: Any] = [
      "session_id": sessionID,
      "transcript_path": "/nonexistent/\(sessionID).jsonl",
      "cwd": cwd,
      "permission_mode": "default",
    ]
    let bash: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "echo hi"]]
    switch moment {
    case .sessionStart:
      input["hook_event_name"] = "SessionStart"
      input["source"] = "startup"
    case .compactRestart:
      input["hook_event_name"] = "SessionStart"
      input["source"] = "compact"
    case .promptSubmitted:
      input["hook_event_name"] = "UserPromptSubmit"
      input["prompt"] = "hi"
    case .toolStarted:
      input["hook_event_name"] = "PreToolUse"
      input.merge(bash) { $1 }
    case .toolFinished:
      input["hook_event_name"] = "PostToolUse"
      input.merge(bash) { $1 }
      input["tool_response"] = ["stdout": "hi\n", "stderr": ""]
    case .permissionNeeded(let message):
      input["hook_event_name"] = "Notification"
      input["notification_type"] = "permission_prompt"
      input["message"] = message
    case .turnEnded:
      input["hook_event_name"] = "Stop"
      input["stop_hook_active"] = false
    case .manualCompact:
      input["hook_event_name"] = "PreCompact"
      input["trigger"] = "manual"
    case .autoCompact:
      input["hook_event_name"] = "PreCompact"
      input["trigger"] = "auto"
    case .subagentToolStarted:
      input["hook_event_name"] = "PreToolUse"
      input.merge(bash) { $1 }
      input["agent_id"] = "agent-1"
      input["agent_type"] = "general-purpose"
    case .sessionEnd:
      input["hook_event_name"] = "SessionEnd"
      input["reason"] = "other"
    case .unknownEvent:
      input["hook_event_name"] = "SomeFutureEvent"
    }
    return input
  }

  /// `claude -p` with the hooks `waiting setup claude` writes passed as `--settings`. Only project
  /// settings (none, in the empty workdir) are loaded, so the user's own hooks don't run, while
  /// auth still comes from their config directory and Keychain.
  func liveInvocation(prompt: String, workdir: URL, scratch: TempDirectory) throws
    -> LiveInvocation
  {
    let config = try scratch.directory("claude-config")
    try WaitingSetup.install(self, configDirectory: config)
    let sessionID = UUID().uuidString.lowercased()
    return LiveInvocation(
      arguments: [
        "-p", prompt,
        "--session-id", sessionID,
        "--settings", config.appending(path: hooksFile).path,
        "--setting-sources", "project",
        "--allowedTools", "Bash(echo:*)",
        "--model", "haiku",
      ],
      keptEnvironment: [configVariable],
      sessionID: sessionID
    )
  }
}
