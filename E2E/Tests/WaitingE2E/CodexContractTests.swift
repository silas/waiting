import Foundation
import Testing

/// Codex's own rules (see `CLI/Codex.swift`, `CLI/CodexSessionIndex.swift`).
@Suite("Codex hooks", .enabled(if: Harnesses.isSelected("codex")))
struct CodexContractTests {
  let harness = CodexHarness()
  let home: TempDirectory
  let hooks: HookRunner
  let sessionID = UUID().uuidString

  init() throws {
    home = try TempDirectory("waiting-e2e-codex")
    hooks = try HookRunner(harness, environment: ["CODEX_HOME": home.url.path])
  }

  func input(_ moment: Moment, _ extra: [String: Any] = [:]) -> [String: Any] {
    harness.input(for: moment, sessionID: sessionID, cwd: "/tmp/demo")!.merging(extra) { $1 }
  }

  @Test func permissionMessageFallsBackToToolName() async throws {
    let event = try await hooks.event(
      input(.permissionNeeded(message: ""), ["tool_name": "apply_patch", "tool_input": [:]]))
    #expect(event.state == .needsInput)
    #expect(event.message == "Approve apply_patch")
  }

  @Test func nonObjectToolInputIsAccepted() async throws {
    let event = try await hooks.event(
      input(.permissionNeeded(message: ""), ["tool_name": "shell", "tool_input": "ls"]))
    #expect(event.message == "Approve shell")
  }

  @Test func interruptIsIdle() async throws {
    let event = try await hooks.event(input(.turnEnded, ["hook_event_name": "Interrupt"]))
    #expect(event.state == .idle)
  }

  @Test(arguments: ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionEnd"])
  func subagentEventsAreDropped(event: String) async throws {
    try await hooks.expectDropped(
      input(.turnEnded, ["hook_event_name": event, "agent_id": "agent-1"]))
  }

  @Test func locationIsNotAGuessOutsideAnAppServer() async throws {
    let event = try await hooks.event(input(.promptSubmitted))
    #expect(event.details?.locationIsGuess != true)
    #expect(event.process != nil)
  }

  @Test func titleIsTheSessionsLatestName() async throws {
    let lines: [[String: Any]] = [
      ["id": sessionID, "thread_name": "First name", "updated_at": "2026-01-01T00:00:00Z"],
      ["id": "other-session", "thread_name": "Not this one", "updated_at": "2026-01-01T00:00:01Z"],
      ["id": sessionID, "thread_name": "Renamed", "updated_at": "2026-01-01T00:00:02Z"],
      ["id": sessionID, "thread_name": "  ", "updated_at": "2026-01-01T00:00:03Z"],
      ["id": "other-session", "thread_name": "Also not", "updated_at": "2026-01-01T00:00:04Z"],
    ]
    let text = try lines.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try (text + "\n").write(
      to: home.path("session_index.jsonl"), atomically: true, encoding: .utf8)

    #expect(try await hooks.event(input(.turnEnded)).title == "Renamed")
    #expect(try await hooks.event(input(.toolStarted)).title == nil)
  }

  @Test func noIndexMeansNoTitle() async throws {
    #expect(try await hooks.event(input(.sessionStart)).title == nil)
  }

  // MARK: Hook trust

  /// `[hooks.state."<hooks.json>:<event>:0:0"]` tables for every event, as Codex's `/hooks` writes
  /// them after the user trusts freshly installed hooks.
  func trustConfig(disabling disabled: String? = nil) throws -> String {
    let file = try #require(realPath(home.path("hooks.json").path))
    return harness.hookEvents.map { event in
      let key = "\(file):\(snakeCase(event)):0:0"
      let enabled = event == disabled ? "enabled = false\n" : ""
      return "[hooks.state.\"\(key)\"]\ntrusted_hash = \"sha256:e2e\"\n\(enabled)"
    }.joined(separator: "\n")
  }

  func snakeCase(_ event: String) -> String {
    event.reduce(into: "") { result, character in
      if character.isUppercase, !result.isEmpty { result.append("_") }
      result.append(character.lowercased())
    }
  }

  @Test func setupSaysToTrustHooksUntilTheyAre() throws {
    let config = home.path("config.toml")
    let fresh = try WaitingSetup.run(harness, configDirectory: home.url)
    #expect(fresh.status == 0)
    #expect(fresh.output.contains("Open /hooks"))

    try ("model = \"gpt-5\"\n\n" + trustConfig()).write(
      to: config, atomically: true, encoding: .utf8)
    let trusted = try WaitingSetup.run(harness, configDirectory: home.url)
    #expect(trusted.output.contains("already installed"))
    #expect(!trusted.output.contains("Open /hooks"))

    try trustConfig(disabling: "Stop").write(to: config, atomically: true, encoding: .utf8)
    let disabled = try WaitingSetup.run(harness, configDirectory: home.url)
    #expect(disabled.output.contains("Open /hooks"))
  }
}
