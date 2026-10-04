import AppKit

/// Knows how to inspect and drive one terminal app's tabs.
protocol TerminalAdapter {
  var bundleIDs: Set<String> { get }

  /// Stable key for the tab or pane a session lives in, derived from what the CLI captured or
  /// from the key learned by `learnTabKey`.
  func tabKey(for session: Session) -> String?

  /// For terminals whose tabs can't be identified from what the CLI captured: works out the
  /// session's tab key so it can be stored in `Session.learnedTabKey`. `userIsHere` means the
  /// user just typed into the session's tab, so if this terminal is frontmost its focused tab is it.
  func learnTabKey(for session: Session, userIsHere: Bool) -> String?

  /// Key of the tab currently frontmost in this terminal, or nil if unknown. Called on the main
  /// actor about once a second while the terminal is frontmost, so it must be fast.
  func focusedTabKey() -> String?

  /// Selects the tab with this key and raises its window. Bringing the app forward is up to the caller.
  func selectTab(_ tabKey: String) -> TabSelection
}

extension TerminalAdapter {
  func learnTabKey(for session: Session, userIsHere: Bool) -> String? { nil }
}

enum TabSelection {
  case selected
  /// The terminal answered but has no such tab (it was closed).
  case notFound
  /// The terminal couldn't be asked, e.g. Automation permission was denied.
  case failed
}

enum TerminalAdapters {
  static let all: [any TerminalAdapter] = [
    AppleTerminalAdapter(),
    ITermAdapter(),
    GhosttyAdapter(),
    VSCodeAdapter(bundleID: "com.microsoft.VSCode", uriScheme: "vscode"),
    VSCodeAdapter(bundleID: "com.microsoft.VSCodeInsiders", uriScheme: "vscode-insiders"),
    VSCodeAdapter(bundleID: "com.todesktop.230313mzl4w4u92", uriScheme: "cursor"),
    VSCodeAdapter(bundleID: "com.vscodium", uriScheme: "vscodium"),
  ]

  static func adapter(for bundleID: String?) -> (any TerminalAdapter)? {
    guard let bundleID else { return nil }
    return all.first { $0.bundleIDs.contains(bundleID) }
  }

  /// Brings the session's tab to the front, or just the terminal app if it has no adapter or the
  /// adapter can't be asked. Returns false if the tab or the terminal app is gone. Sessions in tmux
  /// get their pane selected first, then the tab of the tmux client it was selected in; they're
  /// only gone if their pane is.
  static func show(_ session: Session) -> Bool {
    guard let location = session.terminal else { return false }
    guard let pane = Tmux.Pane(location) else { return showTab(session) }
    switch Tmux.select(pane) {
    case .notFound:
      return false
    case .selected(let terminal?):
      var outer = session
      outer.terminal = terminal
      // The pane is there even if its client's tab can't be found, so keep the session.
      _ = showTab(outer) || activate(location.bundleID)
      return true
    case .selected(nil), .failed:
      // No client terminal to show the pane in (e.g. detached), but the pane may still be
      // there. The terminal that started the tmux server is the best guess.
      _ = activate(location.bundleID)
      return true
    }
  }

  private static func showTab(_ session: Session) -> Bool {
    // Check first: scripting a terminal that isn't running would launch it.
    guard let location = session.terminal, let app = runningApplication(location.bundleID) else {
      return false
    }
    if let adapter = adapter(for: location.bundleID), let key = adapter.tabKey(for: session),
      adapter.selectTab(key) == .notFound
    {
      return false
    }
    app.activate()
    return true
  }

  /// Brings the app forward. False if it isn't running.
  private static func activate(_ bundleID: String?) -> Bool {
    guard let app = runningApplication(bundleID) else { return false }
    app.activate()
    return true
  }

  private static func runningApplication(_ bundleID: String?) -> NSRunningApplication? {
    bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
  }
}

extension String {
  /// The string as a quoted AppleScript literal.
  var appleScriptLiteral: String {
    "\"" + replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }
}
