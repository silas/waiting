import AppKit
import Darwin

extension TerminalLocation {
  /// `TERM_PROGRAM` values mapped to the terminal's bundle ID.
  private static let termProgramBundleIDs = [
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "ghostty": "com.mitchellh.ghostty",
    "WezTerm": "com.github.wez.wezterm",
    "WarpTerminal": "dev.warp.Warp-Stable",
    "vscode": "com.microsoft.VSCode",
  ]

  /// Detects the terminal this process is running in from the environment and process tree.
  static func detect() -> TerminalLocation? {
    detect(pid: getpid(), environment: ProcessInfo.processInfo.environment)
  }

  /// Detects the terminal a process is running in, given that process's environment. The app uses
  /// this on tmux clients to find the terminal a tmux pane is being shown in.
  static func detect(pid: pid_t, environment env: [String: String]) -> TerminalLocation? {
    let location = TerminalLocation(
      bundleID: detectBundleID(pid: pid, env),
      tty: detectTTY(pid: pid),
      environment: env.filter { environmentKeys.contains($0.key) }
    )
    if location.bundleID == nil, location.tty == nil, location.environment.isEmpty {
      return nil
    }
    return location
  }

  private static func detectBundleID(pid: pid_t, _ env: [String: String]) -> String? {
    // Set by LaunchServices on GUI-launched apps and inherited by their shells. Tells apart
    // terminals that share a TERM_PROGRAM (VS Code and Cursor) and survives tmux.
    if let bundleID = env["__CFBundleIdentifier"], !bundleID.isEmpty {
      return bundleID
    }
    if let program = env["TERM_PROGRAM"], let bundleID = termProgramBundleIDs[program] {
      return bundleID
    }
    // Last resort, since iTerm2's shells are parented to a launchd-owned server process.
    for pid in ProcessTable.ancestors(of: pid) {
      if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
        return bundleID
      }
    }
    return nil
  }

  /// The controlling terminal of the nearest ancestor that has one.
  private static func detectTTY(pid: pid_t) -> String? {
    ProcessTable.ancestors(of: pid).lazy.compactMap {
      ProcessTable.info($0).flatMap(ProcessTable.tty)
    }.first
  }
}
