import Foundation
import Testing

/// What every harness's hook mapping must do, from its native input to the event the CLI posts.
@Suite("Hook contract")
struct HarnessContractTests {
  /// The state each moment maps to; nil means the hook posts nothing.
  static let expectations: [(Moment, WireState?)] = [
    (.sessionStart, .idle),
    (.compactRestart, nil),
    (.promptSubmitted, .working),
    (.toolStarted, .working),
    (.toolFinished, .working),
    (.permissionNeeded(message: "Claude needs your permission to use Bash"), .needsInput),
    (.turnEnded, .needsInput),
    (.manualCompact, .idle),
    (.autoCompact, nil),
    (.subagentToolStarted, nil),
    (.sessionEnd, .ended),
    (.unknownEvent, nil),
  ]

  static var cases: [(any Harness, Int)] {
    Harnesses.all.flatMap { harness in expectations.indices.map { (harness, $0) } }
  }

  @Test("Each moment maps to its state", arguments: cases)
  func mapping(harness: any Harness, index: Int) async throws {
    let (moment, expected) = Self.expectations[index]
    let sessionID = UUID().uuidString
    guard let input = harness.input(for: moment, sessionID: sessionID, cwd: "/tmp/demo") else {
      return
    }
    let hooks = try HookRunner(harness)
    guard let expected else {
      try await hooks.expectDropped(input)
      return
    }
    let event = try await hooks.event(input)
    #expect(event.state == expected, "\(harness) \(moment)")
    #expect(event.sessionID == sessionID)
    if case .permissionNeeded(let message) = moment {
      #expect(event.message == message)
    }
  }

  @Test("The envelope carries the harness, session, cwd and native event", arguments: Harnesses.all)
  func envelope(harness: any Harness) async throws {
    let hooks = try HookRunner(harness)
    let sessionID = UUID().uuidString
    let input = try #require(harness.input(for: .turnEnded, sessionID: sessionID, cwd: "/tmp/demo"))
    let before = Date()
    let event = try await hooks.event(input)
    #expect(event.agent == harness.agent)
    #expect(event.sessionID == sessionID)
    #expect(event.cwd == "/tmp/demo")
    #expect(event.timestamp >= before.addingTimeInterval(-1) && event.timestamp <= Date())
    let native = (input as [String: Any])["hook_event_name"] as? String
    #expect(event.details?.hookEventName == native, "details under the \"\(harness.agent)\" key")
  }

  @Test("The process is the nearest ancestor that isn't a shell", arguments: Harnesses.all)
  func process(harness: any Harness) async throws {
    let hooks = try HookRunner(harness)
    let input = try #require(
      harness.input(for: .turnEnded, sessionID: UUID().uuidString, cwd: "/tmp/demo"))
    // Harnesses run hook commands through a shell. The trailing `true` keeps `sh` from exec'ing
    // the CLI in its place.
    let result = try Subprocess.run(
      URL(filePath: "/bin/sh"), ["-c", "\"$0\" hook \(harness.agent); true", Build.cli.path],
      stdin: JSONSerialization.data(withJSONObject: input),
      environment: Subprocess.minimalEnvironment([
        "WAITING_NOTIFICATION_NAME": hooks.listener.notificationName
      ]))
    #expect(result.status == 0)
    let event = try await hooks.listener.next()
    let pid = getpid()
    #expect(
      event.process == WireProcess(pid: pid, startTime: try #require(ProcessStartTime.of(pid))))
  }

  @Test("The terminal keeps only allowlisted variables", arguments: Harnesses.all)
  func terminal(harness: any Harness) async throws {
    let hooks = try HookRunner(harness)
    let input = try #require(
      harness.input(for: .turnEnded, sessionID: UUID().uuidString, cwd: "/tmp/demo"))
    let event = try await hooks.event(
      input,
      environment: [
        "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:E2E", "SECRET_TOKEN": "nope",
      ])
    let terminal = try #require(event.terminal)
    #expect(terminal.bundleID == "com.googlecode.iterm2")
    #expect(
      terminal.environment == ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:E2E"])
  }

  @Test("Invalid input fails without posting", arguments: Harnesses.all)
  func invalidInput(harness: any Harness) async throws {
    let hooks = try HookRunner(harness)
    let result = try hooks.run(Data("{not json".utf8))
    #expect(result.status == 1)
    #expect(result.errorOutput.contains("invalid hook input"))
    let missingSession = try hooks.run(["hook_event_name": "Stop"])
    #expect(missingSession.status == 1)
    // Nothing was posted: the next event is a later, valid one.
    let sessionID = UUID().uuidString
    let event = try await hooks.event(
      try #require(harness.input(for: .turnEnded, sessionID: sessionID, cwd: "/tmp")))
    #expect(event.sessionID == sessionID)
  }
}
