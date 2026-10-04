import Foundation

/// Adds a `waiting hook claude` command hook for every event in `claudeHookEvents` to the user's
/// Claude Code settings. Hooks previously installed by any copy of `waiting` are replaced, so
/// running it again (e.g. after moving the app) just updates the path.
func setupClaude() {
  let configDirectory =
    ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
  let settingsURL = configDirectory.appending(path: "settings.json")
  let command = hookCommand(agent: "claude")

  var settings: [String: Any] = [:]
  if let data = try? Data(contentsOf: settingsURL) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      fail("\(settingsURL.path) is not a JSON object; fix it and try again")
    }
    settings = object
  }

  var hooks = settings["hooks"] as? [String: Any] ?? [:]
  for event in claudeHookEvents {
    var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
      var group = group
      let entries = (group["hooks"] as? [[String: Any]] ?? []).filter {
        !isWaitingCommand($0["command"] as? String)
      }
      guard !entries.isEmpty else { return nil }
      group["hooks"] = entries
      return group
    }
    groups.append(["hooks": [["type": "command", "command": command]]])
    hooks[event] = groups
  }

  var updated = settings
  updated["hooks"] = hooks
  if NSDictionary(dictionary: updated).isEqual(to: settings) {
    print("Claude Code hooks are already installed in \(settingsURL.path)")
    return
  }

  do {
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      let backupURL = settingsURL.appendingPathExtension("bak")
      try? FileManager.default.removeItem(at: backupURL)
      try FileManager.default.copyItem(at: settingsURL, to: backupURL)
      print("Backed up \(settingsURL.path) to \(backupURL.lastPathComponent)")
    }
    let data = try JSONSerialization.data(
      withJSONObject: updated,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: settingsURL, options: .atomic)
  } catch {
    fail("could not update \(settingsURL.path): \(error.localizedDescription)")
  }

  print("Installed hooks for \(claudeHookEvents.joined(separator: ", ")) in \(settingsURL.path)")
  print("Restart running Claude Code sessions to pick them up.")
}

/// Whether a hook command runs some copy of `waiting` for Claude (`waiting hook claude`, or the
/// older `waiting claude`), wherever it's installed.
private func isWaitingCommand(_ command: String?) -> Bool {
  guard let command else { return false }
  return command.contains(/(^|\/)waiting'?\s+(hook\s+)?claude\s*$/)
}
