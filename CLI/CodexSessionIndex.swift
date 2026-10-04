import Foundation

/// Reads session titles from Codex's `session_index.jsonl` in `$CODEX_HOME`, which gets a line
/// (`{"id", "thread_name", "updated_at"}`) whenever a session is named, by `/rename` or by Codex.
nonisolated enum CodexSessionIndex {
  /// The session's latest name (the last line with its ID), or nil if it isn't in the last 1 MB of
  /// the index, where recent sessions are, or the index can't be read.
  static func title(sessionID: String) -> String? {
    let url = AgentHooks.codex.configDirectory.appending(path: "session_index.jsonl")
    guard let lines = tailLines(of: url) else { return nil }
    let needle = Data(sessionID.utf8)
    for line in lines.reversed() where line.firstRange(of: needle) != nil {
      guard let entry = try? JSONDecoder().decode(Entry.self, from: line), entry.id == sessionID
      else { continue }
      let title = entry.threadName?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let title, !title.isEmpty { return title }
    }
    return nil
  }

  private struct Entry: Decodable {
    let id: String
    let threadName: String?

    enum CodingKeys: String, CodingKey {
      case id
      case threadName = "thread_name"
    }
  }
}
