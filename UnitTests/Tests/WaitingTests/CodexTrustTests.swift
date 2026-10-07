import Foundation
import Testing

@testable import WaitingCore

/// `AgentHooks.areCodexHooksTrusted`: reading Codex's trust records in `config.toml`.
@Suite("Codex trust")
final class CodexTrustTests {
  let hooks = AgentHooks.codex
  let directory: URL
  /// The hooks file, as Waiting sees it. It's in a temporary directory, which is under a symlink
  /// (`/var` → `/private/var`), so keys must be compared by real path.
  let hooksFile: String

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "waiting-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    hooksFile = directory.appending(path: "hooks.json").path
    try Data("{}".utf8).write(to: URL(filePath: hooksFile))
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Each event's groups: Waiting's hook alone in one group, after `before` other groups.
  func settings(before: Int = 0, events: [String]? = nil) -> [String: Any] {
    let other: [String: Any] = ["hooks": [["type": "command", "command": "/usr/bin/true"]]]
    let waiting: [String: Any] = [
      "hooks": [["type": "command", "command": "/Applications/Waiting.app/waiting hook codex"]]
    ]
    let groups = Array(repeating: other, count: before) + [waiting]
    return [
      "hooks": Dictionary(uniqueKeysWithValues: (events ?? hooks.events).map { ($0, groups) })
    ]
  }

  /// One `[hooks.state."<key>"]` table per event, for Waiting's hook at `group`.
  func tables(path: String? = nil, group: Int = 0, except: String? = nil, extra: String = "")
    -> String
  {
    hooks.events.filter { $0 != except }.map { event in
      """
      [hooks.state."\(path ?? hooksFile):\(snakeCase(event)):\(group):0"]
      trusted_hash = "sha256:abc"
      \(extra)
      """
    }.joined(separator: "\n\n")
  }

  func snakeCase(_ event: String) -> String {
    [
      "SessionStart": "session_start", "UserPromptSubmit": "user_prompt_submit",
      "PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use",
      "PermissionRequest": "permission_request", "Stop": "stop", "Interrupt": "interrupt",
      "PreCompact": "pre_compact", "SessionEnd": "session_end",
    ][event]!
  }

  func isTrusted(_ config: String, settings: [String: Any]? = nil, hooksFile: String? = nil)
    -> Bool
  {
    hooks.areCodexHooksTrusted(
      settings: settings ?? self.settings(), hooksFile: hooksFile ?? self.hooksFile,
      config: config)
  }

  @Test func everyHookTrustedAsTables() {
    #expect(isTrusted(tables()))
  }

  @Test func everyHookTrustedInline() {
    let lines = hooks.events.map {
      #""\#(hooksFile):\#(snakeCase($0)):0:0" = { trusted_hash = "sha256:abc" }"#
    }
    #expect(isTrusted("[hooks.state]\n" + lines.joined(separator: "\n")))
  }

  @Test func oneUntrustedEventIsNotTrusted() {
    #expect(!isTrusted(tables(except: "PreToolUse")))
  }

  @Test func turnedOffHookIsNotTrusted() {
    #expect(!isTrusted(tables(extra: "enabled = false")))
  }

  @Test func turnedOffInlineHookIsNotTrusted() {
    let lines = hooks.events.map {
      #""\#(hooksFile):\#(snakeCase($0)):0:0" = { trusted_hash = "x", enabled = false }"#
    }
    #expect(!isTrusted("[hooks.state]\n" + lines.joined(separator: "\n")))
  }

  @Test func turnedOnHookIsTrusted() {
    #expect(isTrusted(tables(extra: "enabled = true")))
  }

  @Test func stateWithoutHashIsNotTrusted() {
    let config = hooks.events.map {
      "[hooks.state.\"\(hooksFile):\(snakeCase($0)):0:0\"]\nenabled = true"
    }
    #expect(!isTrusted(config.joined(separator: "\n")))
  }

  @Test func keysOutsideHooksStateAreIgnored() {
    let config = tables().replacingOccurrences(of: "[hooks.state.", with: "[other.state.")
    #expect(!isTrusted(config))
  }

  @Test func keyIndexesFollowWaitingsGroup() {
    #expect(isTrusted(tables(group: 1), settings: settings(before: 1)))
    #expect(!isTrusted(tables(group: 0), settings: settings(before: 1)))
  }

  @Test func eventWithoutWaitingsHookIsNotTrusted() {
    let settings = settings(events: hooks.events.filter { $0 != "Stop" })
    #expect(!isTrusted(tables(), settings: settings))
  }

  @Test func pathsAreComparedByRealPath() throws {
    // As Codex might write them: through /private, with extra slashes or `..`, or via a symlink.
    let real = try #require(realpath(hooksFile, nil).map { String(cString: $0) })
    let link = directory.deletingLastPathComponent().appending(path: "link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    defer { try? FileManager.default.removeItem(at: link) }

    let name = directory.lastPathComponent
    for path in [
      real, directory.path + "//hooks.json", directory.path + "/../\(name)/hooks.json",
      link.appending(path: "hooks.json").path,
    ] {
      #expect(isTrusted(tables(path: path)), "\(path)")
    }
  }

  @Test func hooksFilePathMayContainColons() throws {
    let colons = directory.appending(path: "a:b:c")
    try FileManager.default.createDirectory(at: colons, withIntermediateDirectories: true)
    let file = colons.appending(path: "hooks.json").path
    try Data("{}".utf8).write(to: URL(filePath: file))
    #expect(isTrusted(tables(path: file), hooksFile: file))
  }

  @Test func keysForAMissingFileDontMatch() {
    #expect(!isTrusted(tables(path: directory.appending(path: "gone.json").path)))
    #expect(!isTrusted(tables(), hooksFile: directory.appending(path: "gone.json").path))
  }
}
