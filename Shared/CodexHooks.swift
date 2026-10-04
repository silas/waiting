import Foundation

extension AgentHooks {
  /// Codex's hooks, in `hooks.json` in `$CODEX_HOME` or `~/.codex`. Codex runs only hooks the user
  /// has trusted in its `/hooks` view, so installing them isn't enough.
  nonisolated static let codex = AgentHooks(
    agent: "codex",
    name: "Codex",
    configVariable: "CODEX_HOME",
    defaultConfigDirectory: ".codex",
    hooksFile: "hooks.json",
    // Keep in sync with the mapping in `CLI/Codex.swift`.
    events: [
      "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
      "Interrupt", "PreCompact", "SessionEnd",
    ],
    isAgentProcess: isCodex,
    isTrusted: isCodexTrusted
  )

  /// Whether a command line runs Codex: the native binary (including its background app server,
  /// which has the same `CODEX_HOME`) or the npm package under Node.
  nonisolated static func isCodex(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return first.split(separator: "/").last == "codex"
      || arguments.dropFirst().first?.contains("/@openai/codex/") == true
  }

  /// Whether every installed hook has been trusted. Codex records trust in `config.toml` as a
  /// `[hooks.state."<hooks file>:<event>:<group index>:<handler index>"]` table with a
  /// `trusted_hash`. The hash covers the hook's command, so a hook whose path was updated is
  /// untrusted again, but this only checks that some hash is there.
  nonisolated private static func isCodexTrusted(_ hooks: AgentHooks) -> Bool {
    guard let settings = try? hooks.loadSettings(),
      let data = try? Data(contentsOf: hooks.configDirectory.appending(path: "config.toml"))
    else { return false }
    // Compare real paths: Codex may write the hooks file's path differently (a symlinked or
    // relative `CODEX_HOME`, a trailing slash).
    let trusted = Set(
      trustedKeys(inConfig: String(decoding: data, as: UTF8.self)).compactMap(canonicalKey))
    guard let file = realPath(hooks.settingsURL.path) else { return false }
    let events = settings["hooks"] as? [String: Any] ?? [:]
    return hooks.events.allSatisfy { event in
      let groups = events[event] as? [[String: Any]] ?? []
      for (groupIndex, group) in groups.enumerated() {
        let entries = group["hooks"] as? [[String: Any]] ?? []
        for (handlerIndex, entry) in entries.enumerated()
        where hooks.isWaitingCommand(entry["command"] as? String) {
          return trusted.contains("\(file):\(snakeCase(event)):\(groupIndex):\(handlerIndex)")
        }
      }
      return false
    }
  }

  /// The `hooks.state` keys that have a `trusted_hash`, whether written as a table
  /// (`[hooks.state."<key>"]` then `trusted_hash = …`) or inline (`"<key>" = { trusted_hash = … }`
  /// under `[hooks.state]`), except hooks turned off in `/hooks` (`enabled = false`), which Codex
  /// doesn't run either. A plain scan rather than a TOML parser.
  nonisolated private static func trustedKeys(inConfig config: String) -> Set<String> {
    var keys: Set<String> = []
    var disabled: Set<String> = []
    var table: String?
    for line in config.split(whereSeparator: \.isNewline) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        table = line.wholeMatch(of: #/\[\s*hooks\.state\."([^"]+)"\s*\]/#).map { String($0.1) }
        if line.wholeMatch(of: #/\[\s*hooks\.state\s*\]/#) != nil { table = "" }
        continue
      }
      guard let table else { continue }
      let key: String
      if !table.isEmpty {
        key = table
      } else if let match = line.firstMatch(of: #/^"([^"]+)"\s*=/#) {
        key = String(match.1)
      } else {
        continue
      }
      if line.contains("trusted_hash") { keys.insert(key) }
      if line.contains(#/\benabled\s*=\s*false\b/#) { disabled.insert(key) }
    }
    return keys.subtracting(disabled)
  }

  /// The trust key with its hooks file path resolved by `realPath`, or nil if that file is gone.
  /// The path can contain colons, but the event and indices after it can't.
  nonisolated private static func canonicalKey(_ key: String) -> String? {
    let parts = key.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count > 3, let path = realPath(parts.dropLast(3).joined(separator: ":"))
    else { return nil }
    return ([path] + parts.suffix(3).map(String.init)).joined(separator: ":")
  }

  /// The absolute path with symlinks, `.`, `..` and extra slashes resolved, or nil if it doesn't
  /// exist. Not `URL.resolvingSymlinksInPath()`, which turns `/private/tmp` back into `/tmp`.
  nonisolated private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// `PreToolUse` → `pre_tool_use`, as Codex names events in trust keys.
  nonisolated private static func snakeCase(_ event: String) -> String {
    event.reduce(into: "") { result, character in
      if character.isUppercase, !result.isEmpty { result.append("_") }
      result.append(character.lowercased())
    }
  }
}
