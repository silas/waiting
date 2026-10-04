import AppKit
import Observation

/// Tracks which terminal tab is frontmost, for terminals that have a `TerminalAdapter`.
@Observable final class FocusMonitor {
  struct Focus: Equatable {
    let bundleID: String
    let tabKey: String
    /// tmux panes shown by clients running in this terminal app, so switching tmux windows
    /// counts as a focus change. Which of them is in the focused tab is up to `isFocused`.
    var tmuxViews: Set<Tmux.View> = []
  }

  private(set) var focused: Focus?

  /// Called whenever `focused` changes.
  @ObservationIgnored var onChange: (() -> Void)?

  /// tmux servers that sessions are running in. Only these are queried, so tmux isn't run at all
  /// unless some session is in it.
  @ObservationIgnored var tmuxServers: Set<Tmux.Server> = []

  /// Switching tabs inside a terminal posts no notification, so poll while one is frontmost.
  @ObservationIgnored private var timer: Timer?

  init() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refresh()
      }
    }
    refresh()
  }

  func refresh() {
    guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      let adapter = TerminalAdapters.adapter(for: bundleID)
    else {
      update(nil)
      timer?.invalidate()
      timer = nil
      return
    }

    update(
      adapter.focusedTabKey().map {
        Focus(
          bundleID: bundleID, tabKey: $0, tmuxViews: Tmux.views(in: bundleID, servers: tmuxServers))
      })
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refresh()
        }
      }
    }
  }

  func isFocused(_ session: Session) -> Bool {
    guard let focused, let adapter = TerminalAdapters.adapter(for: focused.bundleID) else {
      return false
    }
    if let pane = Tmux.Pane(session.terminal) {
      // Focused if its pane is current in a tmux client running in the focused tab.
      return focused.tmuxViews.contains { view in
        var outer = session
        outer.terminal = view.terminal
        return view.pane == pane && adapter.tabKey(for: outer) == focused.tabKey
      }
    }
    return session.terminal?.bundleID == focused.bundleID
      && adapter.tabKey(for: session) == focused.tabKey
  }

  /// Only assigns on change, so polling doesn't invalidate observers every second.
  private func update(_ focus: Focus?) {
    if focused != focus {
      focused = focus
      onChange?()
    }
  }
}
