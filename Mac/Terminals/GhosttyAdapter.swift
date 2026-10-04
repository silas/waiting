import AppKit

/// Ghostty. Terminals (panes) are identified by their scripting ID. Ghostty doesn't expose a
/// terminal's tty or tell its shells their ID, so the ID is learned: from the focused terminal
/// when the user has just typed into the session, or else from the only terminal in its directory.
struct GhosttyAdapter: TerminalAdapter {
  private static let bundleID = "com.mitchellh.ghostty"

  let bundleIDs: Set<String> = [Self.bundleID]

  func tabKey(for session: Session) -> String? {
    session.learnedTabKey
  }

  func learnTabKey(for session: Session, userIsHere: Bool) -> String? {
    if userIsHere, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID,
      let focused = focusedTabKey()
    {
      return focused
    }
    guard let cwd = session.cwd,
      let ids = AppleScriptRunner.runList(
        """
        tell application id "\(Self.bundleID)" to get id of (terminals whose working directory is \(cwd.appleScriptLiteral))
        """),
      ids.count == 1
    else { return nil }
    return ids[0]
  }

  func focusedTabKey() -> String? {
    AppleScriptRunner.run(
      """
      tell application id "\(Self.bundleID)" to get id of focused terminal of selected tab of front window
      """)
  }

  func selectTab(_ tabKey: String) -> TabSelection {
    let result = AppleScriptRunner.run(
      """
      tell application id "\(Self.bundleID)"
          set matches to (terminals whose id is \(tabKey.appleScriptLiteral))
          if (count of matches) is 0 then return "notFound"
          focus item 1 of matches
          return "selected"
      end tell
      """)
    switch result {
    case "selected": return .selected
    case "notFound": return .notFound
    default: return .failed
    }
  }
}
