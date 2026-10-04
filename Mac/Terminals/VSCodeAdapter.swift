import AppKit

/// VS Code and its forks. Integrated terminals are identified by their tty, like iTerm2's sessions.
/// These editors can't be scripted, so the Waiting extension (`VSCode/`, installed by
/// `waiting setup vscode`) writes a state file per window listing its terminals' shell PIDs, and
/// selects a terminal when the app opens the window's `showURI`. Without the extension, the
/// editor is just activated.
struct VSCodeAdapter: TerminalAdapter {
  /// Where the extension writes its state files.
  private static let stateDirectory = URL.applicationSupportDirectory.appending(
    path: "dev.waiting.mac/vscode")

  let bundleID: String
  /// The editor's URL scheme (`vscode.env.uriScheme`), which tells its windows' state files apart.
  let uriScheme: String

  var bundleIDs: Set<String> { [bundleID] }

  func tabKey(for session: Session) -> String? {
    session.terminal?.tty
  }

  func focusedTabKey() -> String? {
    guard let pid = windowStates().first(where: \.focused)?.activeTerminalPid else { return nil }
    return tty(of: pid)
  }

  func selectTab(_ tabKey: String) -> TabSelection {
    let states = windowStates()
    guard !states.isEmpty else { return .failed }
    for state in states {
      guard let pid = state.terminalPids.first(where: { tty(of: $0) == tabKey }),
        var components = URLComponents(string: state.showURI)
      else { continue }
      components.queryItems =
        (components.queryItems ?? []) + [URLQueryItem(name: "pid", value: String(pid))]
      guard let url = components.url, NSWorkspace.shared.open(url) else { return .failed }
      return .selected
    }
    return .notFound
  }

  private func tty(of pid: Int32) -> String? {
    ProcessTable.info(pid).flatMap(ProcessTable.tty)
  }

  /// States of this editor's open windows. Files left behind by windows that went away without
  /// cleaning up (e.g. a crash) are deleted.
  private func windowStates() -> [WindowState] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: Self.stateDirectory,
        includingPropertiesForKeys: nil
      )) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let data = try? Data(contentsOf: file),
        let state = try? JSONDecoder().decode(WindowState.self, from: data)
      else { return nil }
      guard ProcessTable.info(state.hostPid) != nil else {
        try? FileManager.default.removeItem(at: file)
        return nil
      }
      return state.uriScheme == uriScheme ? state : nil
    }
  }
}

/// One editor window, as reported by the extension.
private struct WindowState: Decodable {
  let uriScheme: String
  /// PID of the window's extension host, which is gone once the window is.
  let hostPid: Int32
  let focused: Bool
  let activeTerminalPid: Int32?
  /// Shell PIDs of the window's integrated terminals.
  let terminalPids: [Int32]
  /// Opening this (plus `pid=<shell pid>`) focuses the window and selects that terminal.
  let showURI: String
}
