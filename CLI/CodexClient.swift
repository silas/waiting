import Foundation

/// Finds the Codex terminal UI showing a session that runs in Codex's background app server.
nonisolated enum CodexClient {
  /// How recently the user must have typed in a terminal UI for `userJustTyped` to pick it.
  private static let typingWindow: TimeInterval = 3

  /// The PID of the interactive `codex` process showing the session: the only one whose arguments
  /// name the session (`codex resume <id>`), else the only one whose working directory is the
  /// session's. When several share that directory and `userJustTyped` (the hook was triggered by
  /// typing into the session's terminal UI), the one whose terminal was typed into last, if that
  /// was in the last few seconds; `isGuess` is true then, since that can be wrong (a prompt queued
  /// during a turn is submitted when the turn ends, maybe while the user types in another one). Nil
  /// if there's none or it can't be told apart.
  static func find(sessionID: String, cwd: String?, userJustTyped: Bool)
    -> (pid: pid_t, isGuess: Bool)?
  {
    var candidates: [(pid: pid_t, ppid: pid_t, tty: String, arguments: [String])] = []
    for info in ProcessTable.userProcesses() {
      let pid = info.kp_proc.p_pid
      guard let tty = ProcessTable.tty(info),
        let arguments = ProcessTable.commandLine(pid)?.arguments,
        AgentHooks.isCodex(arguments), !arguments.contains("app-server")
      else { continue }
      candidates.append((pid, info.kp_eproc.e_ppid, tty, arguments))
    }
    // The npm package's Node wrapper runs the native binary as its child: keep only the child.
    let parents = Set(candidates.map(\.ppid))
    candidates.removeAll { parents.contains($0.pid) }

    let named = candidates.filter { $0.arguments.contains(sessionID) }
    if named.count == 1 { return (named[0].pid, false) }

    guard let cwd else { return nil }
    let directory = canonical(cwd)
    let inDirectory = candidates.filter {
      ProcessTable.currentDirectory($0.pid).map(canonical) == directory
    }
    if inDirectory.count == 1 { return (inDirectory[0].pid, false) }
    guard userJustTyped else { return nil }

    // The user just pressed Enter in the session's terminal UI, so its terminal was read last.
    let typed = inDirectory.compactMap { candidate in
      ProcessTable.lastInput(tty: candidate.tty).map { (candidate.pid, $0) }
    }
    guard let latest = typed.max(by: { $0.1 < $1.1 }),
      latest.1.timeIntervalSinceNow > -typingWindow
    else { return nil }
    return (latest.0, true)
  }

  /// The path with symlinks resolved, since a process's working directory is (e.g. `/private/tmp`
  /// for `/tmp`).
  private static func canonical(_ path: String) -> String {
    URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
