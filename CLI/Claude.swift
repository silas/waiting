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
  /// Set when the hook fires inside a subagent, which shares its parent's `session_id`.
  let agentID: String?
  /// Stop: the session's background tasks (subagents, shells) and their status.
  let backgroundTasks: [BackgroundTask]?
  /// StopFailure: the kind of API error that ended the turn, such as `rate_limit`.
  let error: String?
  /// StopFailure: the rendered error text.
  let lastAssistantMessage: String?
  /// PreToolUse: the tool being called.
  let toolName: String?
  let toolInput: ToolInput?

  struct BackgroundTask: Decodable {
    let type: String?
    let status: String?
  }

  struct ToolInput: Decodable {
    /// AskUserQuestion: the questions it asks.
    let questions: [Question]?

    struct Question: Decodable {
      let question: String?
    }
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case hookEventName = "hook_event_name"
    case cwd
    case transcriptPath = "transcript_path"
    case message
    case notificationType = "notification_type"
    case source
    case trigger
    case agentID = "agent_id"
    case backgroundTasks = "background_tasks"
    case error
    case lastAssistantMessage = "last_assistant_message"
    case toolName = "tool_name"
    case toolInput = "tool_input"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    hookEventName = try container.decode(String.self, forKey: .hookEventName)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
    agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
    backgroundTasks = try container.decodeIfPresent(
      [BackgroundTask].self, forKey: .backgroundTasks)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    lastAssistantMessage = try container.decodeIfPresent(
      String.self, forKey: .lastAssistantMessage)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    // Its shape depends on the tool, so don't fail on one we don't know.
    toolInput = try? container.decodeIfPresent(ToolInput.self, forKey: .toolInput)
  }
}

/// Notification types for something only the user can answer: a permission or MCP prompt, or a
/// usage-limit wait that didn't resume on its own. Notifications without a type (older Claude
/// Code versions) count too.
nonisolated private let promptNotificationTypes: Set<String?> = [
  nil, "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
  "quota_auto_resume_stale", "quota_auto_resume_disabled",
]

/// Notification types sent as the agent goes back to work: an MCP prompt was answered, or it
/// resumed after a usage limit.
nonisolated private let resumedNotificationTypes: Set<String?> = [
  "elicitation_complete", "elicitation_response", "quota_auto_resume_fired",
]

/// The item subtitle for a turn that ended on an API error (StopFailure's `error`).
nonisolated private func failureMessage(error: String?, text: String?) -> String {
  switch error {
  case "rate_limit": "Rate limited"
  case "overloaded": "API overloaded"
  // Also sent for 529 Overloaded once the retries run out.
  case "server_error": "API server error"
  case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error":
    "Authentication failed"
  case "billing_error", "account_on_hold": "Billing problem"
  case "max_output_tokens": "Output limit reached"
  default: text.flatMap { $0.isEmpty ? nil : $0 } ?? "API error"
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

  // A subagent's own hooks (its tool use) would mark the parent session working while it waits.
  // Its permission and MCP prompts still need the user.
  if input.agentID != nil
    && !(input.hookEventName == "Notification"
      && promptNotificationTypes.contains(input.notificationType))
  {
    return nil
  }

  let state: SessionState
  var message = input.message
  switch input.hookEventName {
  case "Notification" where promptNotificationTypes.contains(input.notificationType):
    state = .needsInput
  case "Notification" where resumedNotificationTypes.contains(input.notificationType):
    state = .working
  case "Notification":
    // Dropped: `idle_prompt`, the "still waiting" reminder sent ~60s after Stop, which carries
    // nothing new and would re-badge a session the user has already seen; `agent_needs_input` and
    // `agent_completed`, the agent view (←) relaying a background session's state, which that
    // session reports with its own hooks (it would badge the agent view's session too);
    // `auth_success`; and types this doesn't know.
    return nil
  case "PreToolUse" where input.toolName == "AskUserQuestion":
    // Asking the user blocks the turn, and in `bypassPermissions` mode no notification follows.
    state = .needsInput
    message = input.toolInput?.questions?.first?.question ?? "Has a question"
  case "PreToolUse" where input.toolName == "ExitPlanMode":
    state = .needsInput
    message = "Plan ready for review"
  case "StopFailure":
    // Sent in place of Stop when the turn ends on an API error.
    state = .needsInput
    message = failureMessage(error: input.error, text: input.lastAssistantMessage)
  case "SessionStart" where input.source == "compact":
    // Sent after compaction, which can happen mid-turn, so it says nothing about the state.
    return nil
  case "Stop"
  where input.backgroundTasks?.contains { $0.type == "subagent" && $0.status == "running" } == true:
    // Subagents run in the background, so the turn ends while they work. When they finish, the
    // agent continues on its own (with a UserPromptSubmit), and its next Stop is the real one.
    state = .working
  case "Stop":
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
    case "PreToolUse" where state == .working, "PostToolUse":
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
    // The hook's `cwd` follows the Bash tool's `cd`, so the session would be renamed after each
    // one. The project directory stays where the session was started.
    cwd: ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? input.cwd,
    // Not for the frequent tool hooks, so they don't read the transcript.
    title: (state == .needsInput
      || ["Stop", "UserPromptSubmit", "SessionStart"].contains(input.hookEventName))
      ? input.transcriptPath.flatMap(ClaudeTranscript.title) : nil,
    message: message,
    terminal: terminal,
    process: process,
    timestamp: Date(),
    claude: ClaudeDetails(hookEventName: input.hookEventName)
  )
}
