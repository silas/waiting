import Foundation

/// The subset of the Claude Code hook input (read from stdin) that we care about.
nonisolated private struct HookInput: Decodable {
  let sessionID: String
  let hookEventName: String
  let cwd: String?
  let message: String?
  let notificationType: String?
  /// SessionStart: `startup`, `resume`, `clear`, `compact` or `fork`.
  let source: String?
  /// PreCompact: `manual` or `auto`.
  let trigger: String?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case hookEventName = "hook_event_name"
    case cwd
    case message
    case notificationType = "notification_type"
    case source
    case trigger
  }
}

/// The hook events `waiting setup claude` installs. Keep in sync with the mapping below.
let claudeHookEvents = [
  "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
  "PreCompact",
  "SessionEnd",
]

/// Maps a Claude Code hook input to an `AgentEvent`, or nil if the hook doesn't change session state.
func claudeEvent(from data: Data) -> AgentEvent? {
  let input: HookInput
  do {
    input = try JSONDecoder().decode(HookInput.self, from: data)
  } catch {
    fail("invalid hook input: \(error)")
  }

  let state: SessionState
  switch input.hookEventName {
  case "Notification" where input.notificationType == "idle_prompt":
    // The "still waiting" reminder sent ~60s after Stop carries nothing new, and would
    // re-badge a session the user has already seen.
    return nil
  case "SessionStart" where input.source == "compact":
    // Sent after compaction, which can happen mid-turn, so it says nothing about the state.
    return nil
  case "Stop", "Notification":
    state = .needsInput
  case "UserPromptSubmit", "PreToolUse", "PostToolUse":
    state = .working
  case "SessionStart",
    "PreCompact" where input.trigger == "manual":
    // The user ran `/compact` at the prompt, so it's not mid-turn. (`where` applies to PreCompact only.)
    state = .idle
  case "SessionEnd":
    state = .ended
  default:
    return nil
  }

  return AgentEvent(
    agent: "claude",
    sessionID: input.sessionID,
    state: state,
    cwd: input.cwd,
    message: input.message,
    terminal: .detect(),
    process: .detectAgent(),
    timestamp: Date(),
    claude: ClaudeDetails(hookEventName: input.hookEventName)
  )
}
