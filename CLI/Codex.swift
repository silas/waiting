import Foundation

/// The subset of the Codex hook input (read from stdin) that we care about.
nonisolated private struct HookInput: Decodable {
  let sessionID: String
  let hookEventName: String
  let cwd: String?
  /// Set on events from a subagent, which carry its parent's `session_id`.
  let agentID: String?
  /// SessionStart: `startup`, `resume`, `clear`, `compact` or `fork`.
  let source: String?
  /// PreCompact: `manual` or `auto`.
  let trigger: String?
  /// PermissionRequest: the tool that needs approval.
  let toolName: String?
  let toolInput: ToolInput?

  struct ToolInput: Decodable {
    /// PermissionRequest: why the tool needs approval, when Codex knows.
    let description: String?
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case hookEventName = "hook_event_name"
    case cwd
    case agentID = "agent_id"
    case source
    case trigger
    case toolName = "tool_name"
    case toolInput = "tool_input"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    hookEventName = try container.decode(String.self, forKey: .hookEventName)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    // Its shape depends on the tool, so don't fail on one that isn't an object.
    toolInput = try? container.decodeIfPresent(ToolInput.self, forKey: .toolInput)
  }
}

/// Maps a Codex hook input to an `AgentEvent`, or nil if the hook doesn't change session state.
func codexEvent(from data: Data) -> AgentEvent? {
  let input: HookInput
  do {
    input = try JSONDecoder().decode(HookInput.self, from: data)
  } catch {
    fail("invalid hook input: \(error)")
  }

  // A subagent's tool calls happen while its parent is working, and its Stop isn't the parent's.
  guard input.agentID == nil else { return nil }

  let state: SessionState
  var message: String?
  switch input.hookEventName {
  case "SessionStart" where input.source == "compact":
    // Sent after compaction, which can happen mid-turn, so it says nothing about the state.
    return nil
  case "Stop":
    state = .needsInput
  case "PermissionRequest":
    state = .needsInput
    message = input.toolInput?.description ?? input.toolName.map { "Approve \($0)" }
  case "UserPromptSubmit", "PreToolUse", "PostToolUse":
    state = .working
  case "SessionStart", "Interrupt",
    "PreCompact" where input.trigger == "manual":
    // The user ran `/compact` at the prompt, so it's not mid-turn. (`where` applies to PreCompact only.)
    state = .idle
  case "SessionEnd":
    state = .ended
  default:
    return nil
  }

  let isToolHook = ["PreToolUse", "PostToolUse"].contains(input.hookEventName)
  let (terminal, process, locationIsGuess) = codexLocation(
    sessionID: input.sessionID, cwd: input.cwd, findClient: !isToolHook,
    userJustTyped: ["UserPromptSubmit", "SessionStart"].contains(input.hookEventName))
  return AgentEvent(
    agent: "codex",
    sessionID: input.sessionID,
    state: state,
    cwd: input.cwd,
    // Not for the frequent tool hooks, so they don't read the index.
    title: ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionStart"].contains(
      input.hookEventName) ? CodexSessionIndex.title(sessionID: input.sessionID) : nil,
    message: message,
    terminal: terminal,
    process: process,
    timestamp: Date(),
    codex: CodexDetails(hookEventName: input.hookEventName, locationIsGuess: locationIsGuess)
  )
}

/// The terminal and the Codex process of the session that ran this hook.
///
/// The terminal UI usually runs its sessions in a background app server shared by every Codex
/// session (`--managed-daemon`), so hooks are the server's children, not the terminal UI's. Then
/// the terminal UI is found among the running `codex` processes, and if it can't be told apart
/// both are nil, which leaves the session's previous ones. IDE extensions and the desktop app run
/// their own app server instead, with no terminal UI, so it isn't searched for: another session's
/// terminal UI in the same directory would be taken as theirs. The server itself is never sent:
/// the managed one never exits, and sessions sharing a server would replace each other.
///
/// Finding the terminal UI scans every process with a tty, so the frequent tool hooks skip it
/// (`findClient` false): they come between the UserPromptSubmit and Stop that start and end the
/// turn, which do find it, and the terminal UI can't change in between.
///
/// `userJustTyped` is for hooks the user triggered by typing into the session's terminal UI
/// (submitting a prompt; launching, `/new` or `/resume`), which tells apart terminal UIs sharing a
/// working directory (see `CodexClient.find`). Not for Stop or PermissionRequest: the user may be
/// typing into another one in the same directory just then. Even then it's a guess, which is
/// returned as `isGuess` so the app trusts it less.
private func codexLocation(
  sessionID: String, cwd: String?, findClient: Bool, userJustTyped: Bool
) -> (terminal: TerminalLocation?, process: AgentProcess?, isGuess: Bool) {
  guard let agent = AgentProcess.detectAgent() else { return (.detect(), nil, false) }
  guard let arguments = ProcessTable.commandLine(agent.pid)?.arguments,
    arguments.contains("app-server")
  else { return (.detect(), agent, false) }
  guard arguments.contains("--managed-daemon") else { return (.detect(), nil, false) }

  guard findClient,
    let client = CodexClient.find(sessionID: sessionID, cwd: cwd, userJustTyped: userJustTyped),
    let info = ProcessTable.info(client.pid)
  else { return (nil, nil, false) }
  let terminal = ProcessTable.environment(client.pid).flatMap {
    TerminalLocation.detect(pid: client.pid, environment: $0)
  }
  return (
    terminal, AgentProcess(pid: client.pid, startTime: ProcessTable.startTime(info)),
    client.isGuess
  )
}
