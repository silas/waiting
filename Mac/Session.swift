import Foundation

struct Session: Codable, Identifiable {
  /// `"\(agent):\(sessionID)"`, so IDs from different harnesses can't collide.
  let id: String
  let agent: String
  var status: SessionState
  var cwd: String?
  /// The agent's title for the session (its `/rename` name or generated title), if any.
  var title: String?
  var message: String?
  var terminal: TerminalLocation?
  /// Tab key worked out by the app, for terminals whose tabs can't be identified from `terminal`
  /// (see `TerminalAdapter.learnTabKey`), with the terminal it was learned in.
  var learnedTab: LearnedTab?
  var process: AgentProcess?
  var lastUpdated: Date

  struct LearnedTab: Codable {
    let key: String
    /// For sessions in tmux, the terminal of the tmux client, which changes when tmux is
    /// reattached elsewhere.
    let terminal: TerminalLocation
  }

  /// The learned tab key, if it was learned in `terminal`. For sessions in tmux, ask this of
  /// `Tmux.outer`'s session, whose `terminal` is the tmux client's.
  var learnedTabKey: String? {
    learnedTab.flatMap { $0.terminal == terminal ? $0.key : nil }
  }

  /// The name shown for the session: its working directory's name.
  var name: String {
    cwd.map { URL(filePath: $0).lastPathComponent } ?? id
  }
}

extension Session {
  /// Sessions waiting on a human first, longest-waiting first; then the rest, most recent first.
  static func menuOrder(_ sessions: some Sequence<Session>) -> [Session] {
    sessions.sorted {
      let waiting0 = $0.status == .needsInput
      let waiting1 = $1.status == .needsInput
      if waiting0 != waiting1 {
        return waiting0
      }
      return waiting0 ? $0.lastUpdated < $1.lastUpdated : $0.lastUpdated > $1.lastUpdated
    }
  }

  /// The session `SessionStore.showNext` shows, from `sorted` (in menu order): the one waiting
  /// longest, else the one after the current one, wrapping around. The current one is the first
  /// in the focused tab, else the one last shown if its terminal is still frontmost
  /// (`wasLastShownHere`); with neither, the first. Sessions with no terminal yet are skipped, and
  /// so are others in the current one's tab, or cycling would get stuck on them.
  static func next(
    in sorted: [Session], isFocused: (Session) -> Bool, wasLastShownHere: (Session) -> Bool
  ) -> Session? {
    if let waiting = sorted.first, waiting.status == .needsInput {
      return waiting
    }
    // Sessions with no terminal yet can't be shown, and nothing could tell they're current, so
    // cycling would keep returning to them.
    let sorted = sorted.filter { $0.terminal != nil }
    guard
      let current = sorted.firstIndex(where: isFocused)
        ?? sorted.firstIndex(where: wasLastShownHere)
    else {
      return sorted.first
    }
    let rest = sorted[(current + 1)...] + sorted[..<current]
    return rest.first { !isFocused($0) } ?? sorted[current]
  }
}
