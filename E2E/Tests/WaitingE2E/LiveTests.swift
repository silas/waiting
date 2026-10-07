import Foundation
import Testing

/// Runs the real agents, so they check what the contract tests assume about each harness's hook
/// inputs. They need the agent installed and signed in, and spend tokens, so they only run with
/// `WAITING_E2E_LIVE=1` (`make e2e-live`).
@Suite(
  "Live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["WAITING_E2E_LIVE"] == "1"))
struct LiveTests {
  static let prompt =
    "Run the shell command `echo waiting-e2e` with your shell tool, then reply with the word done."

  @Test("A one-tool turn reports idle, working, needs input, ended", arguments: Harnesses.all)
  func oneToolTurn(harness: any Harness) async throws {
    let executable = try #require(
      Subprocess.which(harness.executable), "\(harness.executable) isn't on PATH")
    let scratch = try TempDirectory("waiting-e2e-live")
    let workdir = try scratch.directory("project")
    let app = try TestApp()
    try await app.launch()
    let listener = try EventListener(notificationName: app.notificationName)

    let invocation = try harness.liveInvocation(
      prompt: Self.prompt, workdir: workdir, scratch: scratch)
    let result = try Subprocess.run(
      executable, invocation.arguments,
      environment: Subprocess.inheritedEnvironment(
        invocation.environment.merging(["WAITING_NOTIFICATION_NAME": app.notificationName]) {
          $1
        }, keeping: invocation.keptEnvironment),
      directory: workdir, timeout: 300)
    try #require(
      result.status == 0, "\(harness.executable) failed: \(result.errorOutput)\(result.output)")

    let events = try await listener.events(through: { $0.state == .ended })
    let summary = events.map { "\($0.details?.hookEventName ?? "?")→\($0.state)" }
    let sessionID = try #require(events.first?.sessionID)
    if let expected = invocation.sessionID {
      #expect(sessionID == expected)
    }
    for event in events {
      #expect(event.agent == harness.agent)
      #expect(event.sessionID == sessionID, "\(summary)")
      #expect(event.cwd.flatMap(realPath) == workdir.path)
    }

    // Hooks run one at a time, so their events arrive in order.
    let states = events.map(\.state)
    #expect(states.first == .idle, "\(summary)")
    #expect(Array(states.suffix(2)) == [.needsInput, .ended], "\(summary)")
    let middle = states.dropFirst().dropLast(2)
    #expect(!middle.isEmpty && middle.allSatisfy { $0 == .working }, "\(summary)")
    #expect(events.contains { $0.details?.hookEventName == "PreToolUse" }, "\(summary)")
    #expect(events.contains { $0.process != nil })

    // The app saw the wait, then the end.
    let id = "\(harness.agent):\(sessionID)"
    let state = try await app.waitForState {
      $0.startedWaiting.contains(id) && $0.session(id) == nil
    }
    #expect(state.waitingCount == 0)
  }
}
