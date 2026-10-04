import Foundation

/// iTerm2. Sessions (panes) are identified by their tty.
struct ITermAdapter: TerminalAdapter {
  let bundleIDs: Set<String> = ["com.googlecode.iterm2"]

  func tabKey(for session: Session) -> String? {
    session.terminal?.tty
  }

  func focusedTabKey() -> String? {
    AppleScriptRunner.run(
      """
      tell application id "com.googlecode.iterm2" to get tty of current session of current window
      """)
  }

  func selectTab(_ tabKey: String) -> TabSelection {
    let result = AppleScriptRunner.run(
      """
      tell application id "com.googlecode.iterm2"
          repeat with w in windows
              repeat with t in tabs of w
                  repeat with s in sessions of t
                      if tty of s is \(tabKey.appleScriptLiteral) then
                          select w
                          select t
                          select s
                          return "selected"
                      end if
                  end repeat
              end repeat
          end repeat
          return "notFound"
      end tell
      """)
    switch result {
    case "selected": return .selected
    case "notFound": return .notFound
    default: return .failed
    }
  }
}
