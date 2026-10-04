import Foundation

/// The harness-neutral state of an agent session.
nonisolated enum SessionState: String, Codable, Sendable {
  case idle
  case working
  case needsInput
  case ended
}

/// The event the CLI sends to the menu bar app. Each `waiting <agent>` subcommand maps its
/// harness's native input to this envelope, so the app never sees harness-specific event names.
/// Compiled into both targets, so this is the single definition of the wire format.
nonisolated struct AgentEvent: Codable, Sendable {
  static let notificationName = Notification.Name("dev.waiting.mac.agent-event")

  /// The harness that sent the event, e.g. "claude".
  let agent: String
  /// Unique within `agent`.
  let sessionID: String
  let state: SessionState
  let cwd: String?
  /// The session's title, if the harness has one. Nil means unchanged, not cleared.
  var title: String?
  let message: String?
  let terminal: TerminalLocation?
  /// The agent's own process, so the app can drop sessions whose agent exited without an end event.
  let process: AgentProcess?
  let timestamp: Date

  /// Harness-specific extras.
  var claude: ClaudeDetails?
  var codex: CodexDetails?
}

nonisolated struct ClaudeDetails: Codable, Sendable {
  let hookEventName: String
}

nonisolated struct CodexDetails: Codable, Sendable {
  let hookEventName: String
}
