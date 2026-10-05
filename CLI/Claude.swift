import Foundation

/// The subset of the Claude Code hook input (read from stdin) that we care about.
nonisolated private struct HookInput: Decodable {
  let sessionID: String
  let hookEventName: String
  let cwd: String?
  let transcriptPath: String?
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
    case transcriptPath = "transcript_path"
    case message
    case notificationType = "notification_type"
    case source
    case trigger
  }
}

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
  case "Notification"
  where ["agent_needs_input", "agent_completed"].contains(input.notificationType):
    // The agent view (←) relaying a background session's state, which that session reports with
    // its own hooks. It would badge the agent view's session too.
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

  let process = AgentProcess.detectAgent()
  let terminal: TerminalLocation?
  if let jobID = ClaudeAttach.backgroundJobID(sessionID: input.sessionID, agent: process) {
    // Finding the attach process scans every process with a tty, so the frequent tool hooks skip
    // it and leave the terminal unchanged.
    switch input.hookEventName {
    case "PreToolUse", "PostToolUse":
      terminal = nil
    case "UserPromptSubmit":
      terminal = ClaudeAttach.clientLocation(jobID: jobID) ?? ClaudeAttach.viewerLocation()
    default:
      terminal = ClaudeAttach.clientLocation(jobID: jobID)
    }
  } else {
    terminal = .detect()
  }

  return AgentEvent(
    agent: "claude",
    sessionID: input.sessionID,
    state: state,
    cwd: input.cwd,
    // Not for the frequent tool hooks, so they don't read the transcript.
    title: ["Stop", "Notification", "UserPromptSubmit", "SessionStart"].contains(
      input.hookEventName) ? input.transcriptPath.flatMap(ClaudeTranscript.title) : nil,
    message: input.message,
    terminal: terminal,
    process: process,
    timestamp: Date(),
    claude: ClaudeDetails(hookEventName: input.hookEventName)
  )
}
