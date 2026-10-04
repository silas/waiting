import Foundation

/// Reads session metadata from a Claude Code transcript (`transcript_path` in the hook input), a
/// JSONL file of entries.
nonisolated enum ClaudeTranscript {
  /// The session's title: the one the user set with `/rename` (a `custom-title` entry), or else the
  /// one Claude Code generated (`ai-title`). The latest entry of each kind wins. Nil if neither is
  /// in the last 1 MB of the file (Claude Code re-appends its title entries as the session goes on,
  /// so the latest is near the end), or the file can't be read.
  static func title(at path: String) -> String? {
    guard let lines = tailLines(of: URL(filePath: path)) else { return nil }
    var aiTitle: String?
    let needle = Data("-title\"".utf8)
    for line in lines.reversed() {
      // Skip decoding the vast majority of lines, which are messages.
      guard line.count < 4096, line.firstRange(of: needle) != nil else { continue }
      guard let entry = try? JSONDecoder().decode(TitleEntry.self, from: line) else { continue }
      switch entry.type {
      case "custom-title":
        if let title = entry.customTitle.flatMap(nonEmpty) { return title }
      case "ai-title" where aiTitle == nil:
        aiTitle = entry.aiTitle.flatMap(nonEmpty)
      default:
        break
      }
    }
    return aiTitle
  }

  private static func nonEmpty(_ string: String) -> String? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private struct TitleEntry: Decodable {
    let type: String
    let customTitle: String?
    let aiTitle: String?
  }
}
