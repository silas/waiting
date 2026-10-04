import Foundation

/// Finds the Codex terminal UI showing a session that runs in Codex's background app server.
nonisolated enum CodexClient {
  /// The PID of the interactive `codex` process showing the session: the only one whose arguments
  /// name the session (`codex resume <id>`), else the only one whose working directory is the
  /// session's. Nil if there's none or more than one.
  static func find(sessionID: String, cwd: String?) -> pid_t? {
    var candidates: [(pid: pid_t, ppid: pid_t, arguments: [String])] = []
    for info in ProcessTable.userProcesses() {
      let pid = info.kp_proc.p_pid
      guard ProcessTable.tty(info) != nil,
        let arguments = ProcessTable.commandLine(pid)?.arguments,
        AgentHooks.isCodex(arguments), !arguments.contains("app-server")
      else { continue }
      candidates.append((pid, info.kp_eproc.e_ppid, arguments))
    }
    // The npm package's Node wrapper runs the native binary as its child: keep only the child.
    let parents = Set(candidates.map(\.ppid))
    candidates.removeAll { parents.contains($0.pid) }

    let named = candidates.filter { $0.arguments.contains(sessionID) }
    if named.count == 1 { return named[0].pid }

    guard let cwd else { return nil }
    let directory = canonical(cwd)
    let inDirectory = candidates.filter {
      ProcessTable.currentDirectory($0.pid).map(canonical) == directory
    }
    return inDirectory.count == 1 ? inDirectory[0].pid : nil
  }

  /// The path with symlinks resolved, since a process's working directory is (e.g. `/private/tmp`
  /// for `/tmp`).
  private static func canonical(_ path: String) -> String {
    URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
