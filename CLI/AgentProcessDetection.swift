import Darwin

extension AgentProcess {
  private static let shells: Set<String> = [
    "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh",
  ]

  /// The agent that ran this hook: the nearest ancestor that isn't a shell, since harnesses
  /// usually run hook commands through `sh -c`.
  static func detectAgent() -> AgentProcess? {
    for pid in ProcessTable.ancestors().dropFirst() {
      guard let info = ProcessTable.info(pid) else { continue }
      if !shells.contains(ProcessTable.name(info)) {
        return AgentProcess(pid: pid, startTime: ProcessTable.startTime(info))
      }
    }
    return nil
  }
}
