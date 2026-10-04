import Foundation

/// Terminal.app. Tabs are identified by their tty.
struct AppleTerminalAdapter: TerminalAdapter {
  let bundleIDs: Set<String> = ["com.apple.Terminal"]

  func tabKey(for session: Session) -> String? {
    session.terminal?.tty
  }

  func focusedTabKey() -> String? {
    AppleScriptRunner.run(
      """
      tell application id "com.apple.Terminal" to get tty of selected tab of front window
      """)
  }

  func selectTab(_ tabKey: String) -> TabSelection {
    let result = AppleScriptRunner.run(
      """
      tell application id "com.apple.Terminal"
          repeat with w in windows
              repeat with t in tabs of w
                  if tty of t is \(tabKey.appleScriptLiteral) then
                      set miniaturized of w to false
                      set selected of t to true
                      set index of w to 1
                      return "selected"
                  end if
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
