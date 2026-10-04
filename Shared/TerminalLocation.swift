import Foundation

/// Where an agent session is running, as captured by the CLI. Raw identifiers are kept rather than
/// interpreted, so supporting a new terminal is usually just an app-side `TerminalAdapter`.
nonisolated struct TerminalLocation: Codable, Sendable, Hashable {
  /// Bundle ID of the terminal app, e.g. `com.googlecode.iterm2`.
  var bundleID: String?
  /// Controlling terminal of the agent process, e.g. `/dev/ttys003`.
  var tty: String?
  /// Terminal-specific environment variables (see `environmentKeys`).
  var environment: [String: String]

  static let environmentKeys = [
    "TERM_PROGRAM",
    "TERM_SESSION_ID",
    "ITERM_SESSION_ID",
    "KITTY_WINDOW_ID",
    "KITTY_LISTEN_ON",
    "WEZTERM_PANE",
    "WEZTERM_UNIX_SOCKET",
    "TMUX",
    "TMUX_PANE",
  ]
}
