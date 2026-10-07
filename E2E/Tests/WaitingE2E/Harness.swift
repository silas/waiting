import Foundation

/// An agent harness whose hooks run `waiting hook <agent>`. To test a new harness, write a
/// conforming type in `Harnesses/` and add it to `Harnesses.registered`: the shared contract, setup,
/// app and live tests then run against it. Rules only it has go in its own test file.
protocol Harness: Sendable, CustomStringConvertible {
  /// The CLI's argument and `AgentEvent.agent`, e.g. "claude".
  var agent: String { get }
  /// The environment variable that points the CLI at the agent's config directory.
  var configVariable: String { get }
  /// The hooks file `waiting setup` writes in the config directory.
  var hooksFile: String { get }
  /// The hook events `waiting setup` must install.
  var hookEvents: [String] { get }

  /// The harness's native hook input for a moment in a session, or nil if it has no such hook.
  func input(for moment: Moment, sessionID: String, cwd: String) -> [String: Any]?

  /// The agent's executable, looked up on `PATH` for the live tests.
  var executable: String { get }
  /// Prepares a non-interactive run of the agent in `workdir` that runs `prompt`, with Waiting's
  /// hooks installed (via `waiting setup`, into a directory under `scratch`) and the user's own
  /// hooks not run.
  func liveInvocation(prompt: String, workdir: URL, scratch: TempDirectory) throws
    -> LiveInvocation
}

/// A harness-neutral moment in an agent session. The shared tests know what state each should
/// map to (see `HarnessContractTests`).
enum Moment: Sendable, CustomStringConvertible {
  /// A new or resumed session.
  case sessionStart
  /// The session restarting after compaction, which can happen mid-turn.
  case compactRestart
  case promptSubmitted
  case toolStarted
  case toolFinished
  /// The agent is blocked on the user approving something.
  case permissionNeeded(message: String)
  /// The agent finished its turn.
  case turnEnded
  /// The user compacted the conversation at the prompt.
  case manualCompact
  /// The agent compacted the conversation on its own, possibly mid-turn.
  case autoCompact
  /// A subagent used a tool, inside its parent's session.
  case subagentToolStarted
  case sessionEnd
  /// A hook event the CLI doesn't know.
  case unknownEvent

  var description: String {
    switch self {
    case .sessionStart: "sessionStart"
    case .compactRestart: "compactRestart"
    case .promptSubmitted: "promptSubmitted"
    case .toolStarted: "toolStarted"
    case .toolFinished: "toolFinished"
    case .permissionNeeded: "permissionNeeded"
    case .turnEnded: "turnEnded"
    case .manualCompact: "manualCompact"
    case .autoCompact: "autoCompact"
    case .subagentToolStarted: "subagentToolStarted"
    case .sessionEnd: "sessionEnd"
    case .unknownEvent: "unknownEvent"
    }
  }
}

/// How to run an agent for a live test.
struct LiveInvocation {
  var arguments: [String]
  /// Added to the tests' environment.
  var environment: [String: String] = [:]
  /// Variables of the tests' environment to keep, which are otherwise removed (see
  /// `Subprocess.inheritedEnvironment`).
  var keptEnvironment: Set<String> = []
  /// The session ID, when the invocation chooses it.
  var sessionID: String?
}

enum Harnesses {
  static let registered: [any Harness] = [ClaudeHarness(), CodexHarness()]

  /// The harnesses to test: all, or those named in `WAITING_E2E_AGENTS` (comma-separated).
  static var all: [any Harness] {
    registered.filter { isSelected($0.agent) }
  }

  static func isSelected(_ agent: String) -> Bool {
    let selected = (ProcessInfo.processInfo.environment["WAITING_E2E_AGENTS"] ?? "")
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    return selected.isEmpty || selected.contains(agent)
  }
}
