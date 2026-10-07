import Foundation

struct CodexHarness: Harness {
  let agent = "codex"
  let configVariable = "CODEX_HOME"
  let hooksFile = "hooks.json"
  let hookEvents = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
    "Interrupt", "PreCompact", "SessionEnd",
  ]
  let executable = "codex"
  var description: String { "Codex" }

  func input(for moment: Moment, sessionID: String, cwd: String) -> [String: Any]? {
    var input: [String: Any] = [
      "session_id": sessionID,
      "cwd": cwd,
      "model": "gpt-5",
      "transcript_path": NSNull(),
    ]
    let shell: [String: Any] = [
      "tool_name": "Bash", "tool_input": ["command": "echo hi"], "turn_id": "turn-1",
    ]
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
      input["turn_id"] = "turn-1"
    case .toolStarted:
      input["hook_event_name"] = "PreToolUse"
      input.merge(shell) { $1 }
    case .toolFinished:
      input["hook_event_name"] = "PostToolUse"
      input.merge(shell) { $1 }
      input["tool_response"] = "hi\n"
    case .permissionNeeded(let message):
      input["hook_event_name"] = "PermissionRequest"
      input.merge(shell) { $1 }
      input["tool_input"] = ["command": "rm -rf build", "description": message]
    case .turnEnded:
      input["hook_event_name"] = "Stop"
      input["turn_id"] = "turn-1"
      input["stop_hook_active"] = false
    case .manualCompact:
      input["hook_event_name"] = "PreCompact"
      input["trigger"] = "manual"
    case .autoCompact:
      input["hook_event_name"] = "PreCompact"
      input["trigger"] = "auto"
    case .subagentToolStarted:
      input["hook_event_name"] = "PreToolUse"
      input.merge(shell) { $1 }
      input["agent_id"] = "agent-1"
    case .sessionEnd:
      input["hook_event_name"] = "SessionEnd"
    case .unknownEvent:
      input["hook_event_name"] = "SomeFutureEvent"
    }
    return input
  }

  /// `codex exec` with a scratch `CODEX_HOME` holding the hooks `waiting setup codex` writes (the
  /// user's own hooks file isn't read) and a link to the user's `auth.json`. Hook trust is
  /// bypassed, since trusting needs the interactive `/hooks` view.
  func liveInvocation(prompt: String, workdir: URL, scratch: TempDirectory) throws
    -> LiveInvocation
  {
    let home = try scratch.directory("codex-home")
    try WaitingSetup.install(self, configDirectory: home)
    let userHome =
      ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    let auth = userHome.appending(path: "auth.json")
    if FileManager.default.fileExists(atPath: auth.path) {
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: "auth.json"), withDestinationURL: auth)
    }
    return LiveInvocation(
      arguments: [
        "exec", "--json", "--dangerously-bypass-hook-trust", "--skip-git-repo-check",
        "-C", workdir.path, prompt,
      ],
      environment: [configVariable: home.path]
    )
  }
}
