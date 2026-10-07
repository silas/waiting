import Foundation
import Testing

/// Claude Code's own rules (see `CLI/Claude.swift`).
@Suite("Claude Code hooks", .enabled(if: Harnesses.isSelected("claude")))
struct ClaudeContractTests {
  let harness = ClaudeHarness()
  let hooks: HookRunner
  let sessionID = UUID().uuidString

  init() throws {
    hooks = try HookRunner(harness)
  }

  func input(_ moment: Moment, _ extra: [String: Any] = [:]) -> [String: Any] {
    harness.input(for: moment, sessionID: sessionID, cwd: "/tmp/demo")!.merging(extra) { $1 }
  }

  @Test func stopWithRunningSubagentIsWorking() async throws {
    let tasks: [[String: Any]] = [
      ["type": "subagent", "status": "running"], ["type": "shell", "status": "completed"],
    ]
    let event = try await hooks.event(input(.turnEnded, ["background_tasks": tasks]))
    #expect(event.state == .working)
  }

  @Test func stopWithOnlyRunningShellNeedsInput() async throws {
    let tasks: [[String: Any]] = [
      ["type": "shell", "status": "running"], ["type": "subagent", "status": "completed"],
    ]
    let event = try await hooks.event(input(.turnEnded, ["background_tasks": tasks]))
    #expect(event.state == .needsInput)
  }

  @Test(arguments: ["idle_prompt", "agent_needs_input", "agent_completed"])
  func droppedNotifications(type: String) async throws {
    try await hooks.expectDropped(
      input(.permissionNeeded(message: "x"), ["notification_type": type]))
  }

  @Test func subagentNotificationIsKept() async throws {
    let event = try await hooks.event(
      input(.permissionNeeded(message: "Subagent needs approval"), ["agent_id": "agent-1"]))
    #expect(event.state == .needsInput)
    #expect(event.message == "Subagent needs approval")
  }

  @Test(arguments: ["Stop", "UserPromptSubmit", "PostToolUse", "SessionEnd"])
  func otherSubagentEventsAreDropped(event: String) async throws {
    try await hooks.expectDropped(
      input(.turnEnded, ["hook_event_name": event, "agent_id": "agent-1"]))
  }

  @Test func projectDirectoryBeatsInputCwd() async throws {
    let event = try await hooks.event(
      input(.turnEnded, ["cwd": "/tmp/demo/subdir"]),
      environment: ["CLAUDE_PROJECT_DIR": "/tmp/demo"])
    #expect(event.cwd == "/tmp/demo")
  }

  @Test func emptyProjectDirectoryFallsBackToInputCwd() async throws {
    let event = try await hooks.event(
      input(.turnEnded, ["cwd": "/tmp/demo/subdir"]), environment: ["CLAUDE_PROJECT_DIR": ""])
    #expect(event.cwd == "/tmp/demo/subdir")
  }

  // MARK: Titles from the transcript

  func transcript(_ entries: [[String: Any]]) throws -> (TempDirectory, String) {
    let directory = try TempDirectory()
    let url = directory.path("transcript.jsonl")
    let lines = try entries.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return (directory, url.path)
  }

  let message: [String: Any] = [
    "type": "assistant", "message": ["role": "assistant", "content": "hello"],
  ]

  @Test func customTitleBeatsLaterAITitle() async throws {
    let (directory, path) = try transcript([
      ["type": "ai-title", "aiTitle": "Old generated", "sessionId": sessionID],
      ["type": "custom-title", "customTitle": "My rename", "sessionId": sessionID],
      message,
      ["type": "ai-title", "aiTitle": "New generated", "sessionId": sessionID],
    ])
    let event = try await hooks.event(input(.turnEnded, ["transcript_path": path]))
    #expect(event.title == "My rename")
    _ = directory
  }

  @Test func latestAITitleWins() async throws {
    let (directory, path) = try transcript([
      ["type": "ai-title", "aiTitle": "First", "sessionId": sessionID],
      message,
      ["type": "ai-title", "aiTitle": "Second", "sessionId": sessionID],
      ["type": "custom-title", "customTitle": "   ", "sessionId": sessionID],
    ])
    let event = try await hooks.event(input(.promptSubmitted, ["transcript_path": path]))
    #expect(event.title == "Second")
    _ = directory
  }

  @Test func toolHooksDontReadTitle() async throws {
    let (directory, path) = try transcript([
      ["type": "custom-title", "customTitle": "Named", "sessionId": sessionID]
    ])
    let event = try await hooks.event(input(.toolStarted, ["transcript_path": path]))
    #expect(event.title == nil)
    _ = directory
  }

  @Test func missingTranscriptHasNoTitle() async throws {
    let event = try await hooks.event(input(.turnEnded))
    #expect(event.title == nil)
  }
}
