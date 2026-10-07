import Foundation
import Testing

/// `waiting setup <agent>` against a scratch config directory (see `Shared/AgentHooks.swift`).
@Suite("Setup")
struct SetupTests {
  /// The commands of every hook installed for `event`, by group then handler.
  func commands(_ settings: [String: Any], _ event: String) -> [[String]] {
    let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.map { group in
      (group["hooks"] as? [[String: Any]] ?? []).map { $0["command"] as? String ?? "" }
    }
  }

  @Test("A fresh install adds a hook for every event", arguments: Harnesses.all)
  func freshInstall(harness: any Harness) throws {
    let config = try TempDirectory()
    let result = try WaitingSetup.run(harness, configDirectory: config.url)
    #expect(result.status == 0, "\(result.errorOutput)")
    let settings = try readJSON(config.path(harness.hooksFile))
    let command = Build.hookCommand(agent: harness.agent)
    for event in harness.hookEvents {
      #expect(commands(settings, event) == [[command]], "\(event)")
    }
    let installed = Set((settings["hooks"] as? [String: Any] ?? [:]).keys)
    #expect(installed == Set(harness.hookEvents))
    let group = try #require(
      ((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first)
    #expect(group["matcher"] == nil)
    #expect((group["hooks"] as? [[String: Any]])?.first?["type"] as? String == "command")
  }

  @Test("Running it again changes nothing", arguments: Harnesses.all)
  func idempotent(harness: any Harness) throws {
    let config = try TempDirectory()
    try WaitingSetup.install(harness, configDirectory: config.url)
    let file = config.path(harness.hooksFile)
    let before = try Data(contentsOf: file)
    let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
    Thread.sleep(forTimeInterval: 0.01)

    let result = try WaitingSetup.run(harness, configDirectory: config.url)
    #expect(result.status == 0)
    #expect(result.output.contains("already installed"))
    #expect(try Data(contentsOf: file) == before)
    #expect(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        == modified as? Date)
    #expect(!FileManager.default.fileExists(atPath: file.path + ".bak"))
  }

  @Test(
    "Other hooks and settings are kept, and the old file is backed up", arguments: Harnesses.all)
  func keepsOtherHooks(harness: any Harness) throws {
    let config = try TempDirectory()
    let file = config.path(harness.hooksFile)
    let original: [String: Any] = [
      "model": "custom",
      "hooks": [
        "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
        "PreToolUse": [
          ["matcher": "Bash", "hooks": [["type": "command", "command": "audit-bash"]]]
        ],
        "SomethingElse": [["hooks": [["type": "command", "command": "other"]]]],
      ],
    ]
    try writeJSON(original, to: file)
    let originalData = try Data(contentsOf: file)

    let result = try WaitingSetup.run(harness, configDirectory: config.url)
    #expect(result.status == 0)
    #expect(result.output.contains("Backed up"))
    #expect(try Data(contentsOf: URL(filePath: file.path + ".bak")) == originalData)

    let settings = try readJSON(file)
    let command = Build.hookCommand(agent: harness.agent)
    #expect(settings["model"] as? String == "custom")
    #expect(commands(settings, "Stop") == [["say done"], [command]])
    #expect(commands(settings, "PreToolUse") == [["audit-bash"], [command]])
    #expect(commands(settings, "SomethingElse") == [["other"]])
  }

  @Test("A hook for another copy of waiting is replaced in place", arguments: Harnesses.all)
  func replacesOutdated(harness: any Harness) throws {
    let config = try TempDirectory()
    let file = config.path(harness.hooksFile)
    let old = "'/Volumes/Old Copy/Waiting.app/Contents/Helpers/waiting' hook \(harness.agent)"
    try writeJSON(
      [
        "hooks": [
          "Stop": [
            ["hooks": [["type": "command", "command": "say done"]]],
            [
              "hooks": [
                ["type": "command", "command": "before"], ["type": "command", "command": old],
              ]
            ],
          ]
        ]
      ], to: file)

    let result = try WaitingSetup.run(harness, configDirectory: config.url)
    #expect(result.status == 0)
    let settings = try readJSON(file)
    let command = Build.hookCommand(agent: harness.agent)
    // Same group and position, so Codex's trust keys (which use indices) still line up.
    #expect(commands(settings, "Stop") == [["say done"], ["before", command]])
  }

  @Test("A hooks file that isn't a JSON object is left alone", arguments: Harnesses.all)
  func invalidFile(harness: any Harness) throws {
    let config = try TempDirectory()
    let file = config.path(harness.hooksFile)
    try Data("{ \"hooks\": ".utf8).write(to: file)
    let result = try WaitingSetup.run(harness, configDirectory: config.url)
    #expect(result.status == 1)
    #expect(result.errorOutput.contains("not a JSON object"))
    #expect(try Data(contentsOf: file) == Data("{ \"hooks\": ".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path + ".bak"))
  }
}
