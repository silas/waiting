import Foundation

/// Claude Code background sessions (`claude --bg`, or ← in a session) run in a daemon, each on a
/// pty of its own that no terminal shows. A terminal shows one by running `claude attach <job ID>`.
enum ClaudeAttach {
  /// The job ID of the background session whose Claude Code process this is, or nil if it isn't
  /// one. Read from the process's own environment, since Claude Code doesn't pass
  /// `CLAUDE_CODE_SESSION_KIND` on to hooks. `CLAUDE_JOB_DIR` is `~/.claude/jobs/<job ID>`, but
  /// sessions that take over a pre-started process don't have it, and the job ID is the session
  /// ID's first 8 characters.
  static func backgroundJobID(sessionID: String, agent: AgentProcess?) -> String? {
    guard let agent, let environment = ProcessTable.environment(agent.pid),
      environment["CLAUDE_CODE_SESSION_KIND"] == "bg"
    else { return nil }
    if let directory = environment["CLAUDE_JOB_DIR"], !directory.isEmpty {
      return URL(filePath: directory).lastPathComponent
    }
    return String(sessionID.prefix(8))
  }

  /// How the daemon started a background session, from its roster entry.
  nonisolated struct Dispatch: Equatable, Sendable {
    /// The session it was forked from. Sending an interactive session to the background (← or
    /// `/bg`) forks it into a new session ID in the daemon. With ←, the interactive process lives
    /// on as the agent view, so the session it left gets no end event and its process doesn't exit.
    var forkedFrom: String?
    /// Started ahead of time for the agent view's next prompt: until it gets one, it's not a
    /// session the user has started.
    var isSpare: Bool
  }

  /// The roster entry for a background session, or nil if there's none. The roster is
  /// undocumented, so a missing or changed file just gives nil.
  static func dispatch(sessionID: String) -> Dispatch? {
    let url = AgentHooks.claude.configDirectory.appending(path: "daemon/roster.json")
    return (try? Data(contentsOf: url)).flatMap { dispatch(sessionID: sessionID, roster: $0) }
  }

  /// Read field by field rather than decoded, so an entry or field whose shape changes only loses
  /// what it holds: `{"workers": {<job ID>: {"dispatch": {"sessionId", "source", "launch":
  /// {"sessionId", "fork"}}}}}`. `source` is what started it: `slash` (← or `/bg`), `spare` (ahead
  /// of time, for the agent view), …; `launch.sessionId` is the session resumed, a transcript path
  /// or a session ID.
  static func dispatch(sessionID: String, roster: Data) -> Dispatch? {
    guard let root = try? JSONSerialization.jsonObject(with: roster) as? [String: Any],
      let workers = root["workers"] as? [String: Any],
      let dispatch = workers.values.lazy
        .compactMap({ ($0 as? [String: Any])?["dispatch"] as? [String: Any] })
        .first(where: { $0["sessionId"] as? String == sessionID })
    else { return nil }
    var forkedFrom: String?
    if let launch = dispatch["launch"] as? [String: Any], launch["fork"] as? Bool == true,
      let source = launch["sessionId"] as? String, !source.isEmpty
    {
      // A transcript path (`…/<session ID>.jsonl`) or a session ID.
      let id =
        source.hasSuffix(".jsonl")
        ? URL(filePath: source).deletingPathExtension().lastPathComponent : source
      forkedFrom = id == sessionID ? nil : id
    }
    return Dispatch(forkedFrom: forkedFrom, isSpare: dispatch["source"] as? String == "spare")
  }

  /// The PID of the newest `claude attach` process with a terminal that shows the job, or nil if
  /// no terminal is attached to it.
  static func client(jobID: String) -> pid_t? {
    ProcessTable.userProcesses().filter { info in
      guard ProcessTable.tty(info) != nil,
        let arguments = ProcessTable.commandLine(info.kp_proc.p_pid)?.arguments,
        let attach = arguments.dropFirst().firstIndex(of: "attach")
      else { return false }
      return arguments.index(after: attach) < arguments.endIndex
        && arguments[arguments.index(after: attach)] == jobID
    }
    .max { ProcessTable.startTime($0) < ProcessTable.startTime($1) }?.kp_proc.p_pid
  }

  /// Where the job is shown: the terminal of its newest `claude attach` process, or nil if none.
  static func clientLocation(jobID: String) -> TerminalLocation? {
    client(jobID: jobID).flatMap { location($0) }
  }

  /// How recently the user must have typed in the agent view for `viewerLocation` to pick it.
  private static let typingWindow: TimeInterval = 3

  /// The terminal of the agent view (←) the user just typed a prompt into, for a background
  /// session with no `claude attach` process: the agent view shows sessions in its own process, and
  /// nothing outside it says which. So the guess is the interactive Claude Code process whose
  /// terminal was read from last (its access time, as `w` uses for idle time), if that was in the
  /// last few seconds. Only for `UserPromptSubmit`, since it may be wrong otherwise.
  static func viewerLocation() -> TerminalLocation? {
    let typed = ProcessTable.userProcesses().compactMap { info -> (pid_t, Date)? in
      let pid = info.kp_proc.p_pid
      // The daemon's own processes have ttys too (their ptys), but are background sessions.
      guard let tty = ProcessTable.tty(info), let lastInput = ProcessTable.lastInput(tty: tty),
        lastInput.timeIntervalSinceNow > -typingWindow,
        let commandLine = ProcessTable.commandLine(pid),
        AgentHooks.isClaude(commandLine.arguments),
        commandLine.environment["CLAUDE_CODE_SESSION_KIND"] != "bg",
        // `claude --bg <prompt>` just launched the session from a shell, whose tab doesn't show it.
        !commandLine.arguments.contains("--bg")
      else { return nil }
      return (pid, lastInput)
    }
    return typed.max { $0.1 < $1.1 }.flatMap { location($0.0) }
  }

  private static func location(_ pid: pid_t) -> TerminalLocation? {
    TerminalLocation.detect(pid: pid, environment: ProcessTable.environment(pid) ?? [:])
  }
}
