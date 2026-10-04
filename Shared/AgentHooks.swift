import Foundation
import Synchronization

/// The command hooks that run `waiting hook <agent>`, kept in an agent's JSON hooks file. Claude
/// Code and Codex use the same format. Used by both `waiting setup <agent>` and the Integrations
/// tab of Settings. The agents are `AgentHooks.claude` and `AgentHooks.codex`.
nonisolated struct AgentHooks: Sendable {
  /// The `agent` of its events and the CLI's argument, e.g. "claude".
  let agent: String
  /// Shown in Settings and the CLI's messages.
  let name: String
  /// The environment variable that overrides the config directory, e.g. `CLAUDE_CONFIG_DIR`.
  let configVariable: String
  /// The config directory's name in the home directory, e.g. `.claude`.
  let defaultConfigDirectory: String
  /// The file the hooks are written to, in the config directory.
  let hooksFile: String
  /// The hook events that get a hook. Keep in sync with the agent's mapping in `CLI/`.
  let events: [String]
  /// Whether a command line runs the agent, to read the config variable from it.
  let isAgentProcess: @Sendable ([String]) -> Bool
  /// Whether the agent has been told to run the installed hooks, for agents that run only hooks
  /// the user has trusted. Nil if it runs any hook.
  var isTrusted: (@Sendable (AgentHooks) -> Bool)?

  enum Status: Sendable {
    case notInstalled
    case installed
    /// Installed, but for another copy of `waiting` or for fewer events.
    case outdated
    /// Installed, but the agent won't run them until the user trusts them.
    case untrusted
  }

  enum InstallResult {
    case alreadyInstalled
    /// `backup` is the copy of the previous hooks file, if there was one.
    case installed(backup: URL?)
  }

  enum InstallError: LocalizedError {
    case noCLI
    case temporaryLocation
    case invalidSettings(URL)
    case writeFailed(URL, String)

    var errorDescription: String? {
      switch self {
      case .noCLI: "could not find the waiting command-line tool"
      case .temporaryLocation:
        "Waiting is running from a disk image or a temporary location; move it to Applications, open it from there, and try again"
      case .invalidSettings(let url): "\(url.path) is not a JSON object; fix it and try again"
      case .writeFailed(let url, let message): "could not update \(url.path): \(message)"
      }
    }
  }

  /// `$<configVariable>`, falling back to `~/<defaultConfigDirectory>`. Blocks the first time it's
  /// read in the app (see `configDirectoryLookup`), so read it off the main actor.
  var configDirectory: URL { configDirectoryLookup().url }

  /// The config directory, and whether it's known. The app doesn't inherit variables set in the
  /// user's shell profile, so it takes the variable from a running copy of the agent, or failing
  /// that asks their login shell. If the shell fails, `url` is the default but isn't known, and it
  /// asks again after 30s.
  func configDirectoryLookup() -> (url: URL, isKnown: Bool) {
    let lookup = configDirectoryOverride()
    if case .set(let path) = lookup { return (URL(filePath: path), true) }
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: defaultConfigDirectory)
    return (url, lookup != .failed)
  }

  /// This agent's last lookup and when it was made. One per agent, so looking up one agent's
  /// variable doesn't wait on another's login shell.
  let lastOverride = LastOverride()

  nonisolated final class LastOverride: Sendable {
    fileprivate let value = Mutex<(lookup: LoginShell.Lookup, date: Date)?>(nil)
  }

  private func configDirectoryOverride() -> LoginShell.Lookup {
    if let value = ProcessInfo.processInfo.environment[configVariable], !value.isEmpty {
      return .set(value)
    }
    // The CLI runs in the user's shell, so its environment is already the right one.
    guard Bundle.main.bundleURL.pathExtension == "app" else { return .unset }
    // Held while looking, so concurrent callers don't each start a shell.
    return lastOverride.value.withLock { last in
      if let last, last.lookup != .failed || last.date.timeIntervalSinceNow > -30 {
        return last.lookup
      }
      let lookup = runningAgentOverride() ?? LoginShell.variable(configVariable)
      last = (lookup, .now)
      return lookup
    }
  }

  /// The config variable in the environment of the most recently started agent process with a
  /// terminal, or nil if none is running. Unlike asking the login shell, this runs none of the
  /// user's code. Only processes with a tty were started from the user's shell profile; others
  /// (an IDE extension's or Claude's desktop app's, Codex's app server) may lack its variables.
  private func runningAgentOverride() -> LoginShell.Lookup? {
    let newest = ProcessTable.userProcesses()
      .sorted { ProcessTable.startTime($0) > ProcessTable.startTime($1) }
    for process in newest {
      guard ProcessTable.tty(process) != nil,
        let (arguments, environment) = ProcessTable.commandLine(process.kp_proc.p_pid),
        isAgentProcess(arguments)
      else { continue }
      if let value = environment[configVariable], !value.isEmpty { return .set(value) }
      return .unset
    }
    return nil
  }

  var settingsURL: URL { configDirectory.appending(path: hooksFile) }

  /// Whether the agent seems to be installed, judged by its config directory existing.
  var isDetected: Bool {
    FileManager.default.fileExists(atPath: configDirectory.path)
  }

  /// `waiting setup <agent>`, for running from a terminal.
  var setupCommand: String {
    let path = WaitingCLI.url?.path ?? "/Applications/Waiting.app/Contents/Helpers/waiting"
    return "\(WaitingCLI.shellQuoted(path)) setup \(agent)"
  }

  func status() -> Status {
    guard let settings = try? loadSettings(),
      let command = WaitingCLI.hookCommand(agent: agent)
    else { return .notInstalled }
    if NSDictionary(dictionary: withHooks(settings, command: command)).isEqual(to: settings) {
      if let isTrusted, !isTrusted(self) { return .untrusted }
      return .installed
    }
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    let hasWaitingHook = hooks.values.contains { groups in
      (groups as? [[String: Any]] ?? []).contains { group in
        (group["hooks"] as? [[String: Any]] ?? []).contains {
          isWaitingCommand($0["command"] as? String)
        }
      }
    }
    return hasWaitingHook ? .outdated : .notInstalled
  }

  /// Adds a hook for every event in `events`. Hooks previously installed by any copy of `waiting`
  /// are replaced, so installing again (e.g. after moving the app) just updates the path. Other
  /// hooks are left alone. The previous file is backed up with a `.bak` extension, and nothing is
  /// written if the hooks are already installed.
  func install() throws -> InstallResult {
    guard let command = WaitingCLI.hookCommand(agent: agent) else { throw InstallError.noCLI }
    guard !WaitingCLI.isTemporaryLocation else { throw InstallError.temporaryLocation }
    let settings = try loadSettings()
    let updated = withHooks(settings, command: command)
    if NSDictionary(dictionary: updated).isEqual(to: settings) {
      return .alreadyInstalled
    }

    let url = settingsURL
    var backup: URL?
    do {
      try FileManager.default.createDirectory(
        at: configDirectory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path) {
        let backupURL = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
        backup = backupURL
      }
      let data = try JSONSerialization.data(
        withJSONObject: updated,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
      try data.write(to: url, options: .atomic)
    } catch {
      throw InstallError.writeFailed(url, error.localizedDescription)
    }
    return .installed(backup: backup)
  }

  /// The hooks file, or empty if it doesn't exist.
  func loadSettings() throws -> [String: Any] {
    let url = settingsURL
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InstallError.invalidSettings(url)
    }
    return object
  }

  /// `settings` with exactly one `waiting` hook, running `command`, for each event.
  private func withHooks(_ settings: [String: Any], command: String) -> [String: Any] {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in events {
      let existing = hooks[event] as? [[String: Any]] ?? []
      // Keep a single current hook in place only if its group covers the entire event.
      // Another tool adding hooks after it should not make it look outdated.
      let waitingEntries = existing.flatMap { group in
        (group["hooks"] as? [[String: Any]] ?? [])
          .filter { isWaitingCommand($0["command"] as? String) }
          .map { (group: group, entry: $0) }
      }
      if waitingEntries.count == 1, isUnrestricted(waitingEntries[0].group),
        waitingEntries[0].entry["command"] as? String == command,
        waitingEntries[0].entry["type"] as? String == "command"
      {
        continue
      }
      // Replace the first unrestricted `waiting` hook in place and drop any others, including
      // restricted hooks. Preserve positions when possible: Codex's trust keys use indices.
      var replaced = false
      var groups = existing.compactMap { group -> [String: Any]? in
        var group = group
        let entries = (group["hooks"] as? [[String: Any]] ?? []).compactMap {
          entry -> [String: Any]? in
          guard isWaitingCommand(entry["command"] as? String) else { return entry }
          guard isUnrestricted(group), !replaced else { return nil }
          replaced = true
          return ["type": "command", "command": command]
        }
        guard !entries.isEmpty else { return nil }
        group["hooks"] = entries
        return group
      }
      if !replaced {
        groups.append(["hooks": [["type": "command", "command": command]]])
      }
      hooks[event] = groups
    }
    var updated = settings
    updated["hooks"] = hooks
    return updated
  }

  private func isUnrestricted(_ group: [String: Any]) -> Bool {
    guard let matcher = group["matcher"] else { return true }
    guard let matcher = matcher as? String else { return false }
    return matcher.isEmpty || matcher == "*"
  }

  /// Whether a hook command runs some copy of `waiting` for this agent (`waiting hook <agent>`, or
  /// the older `waiting <agent>`), wherever it's installed.
  func isWaitingCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    let pattern = "(^|/)waiting'?\\s+(hook\\s+)?\(agent)\\s*$"
    return command.range(of: pattern, options: .regularExpression) != nil
  }
}
