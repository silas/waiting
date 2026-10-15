import Foundation
import Testing

/// The app's handling of events (`Mac/SessionStore.swift`), observed through a copy running in
/// test mode. Events are posted directly, so their timestamps and processes can be chosen.
@Suite("App", .serialized)
struct AppTests {
  let app: TestApp

  init() async throws {
    app = try TestApp()
    try await app.launch()
  }

  func event(
    _ session: String, _ state: WireState, at offset: TimeInterval = 0, agent: String = "claude",
    cwd: String? = nil, title: String? = nil, message: String? = nil,
    terminal: WireTerminal? = nil, process: WireProcess? = nil, details: WireDetails? = nil
  ) -> WireEvent {
    WireEvent(
      agent: agent, sessionID: session, state: state, cwd: cwd, title: title, message: message,
      terminal: terminal, process: process, timestamp: start.addingTimeInterval(offset),
      details: details)
  }

  let start = Date()

  @Test("A hook's event reaches the app", arguments: Harnesses.all)
  func hookToApp(harness: any Harness) async throws {
    let sessionID = UUID().uuidString
    let input = try #require(
      harness.input(for: .turnEnded, sessionID: sessionID, cwd: "/tmp/e2e-project"))
    let result = try Subprocess.run(
      Build.cli, ["hook", harness.agent],
      stdin: JSONSerialization.data(withJSONObject: input),
      environment: Subprocess.minimalEnvironment(["WAITING_NOTIFICATION_NAME": app.notificationName]
      ))
    #expect(result.status == 0)
    let id = "\(harness.agent):\(sessionID)"
    let state = try await app.waitForState { $0.session(id) != nil }
    let session = try #require(state.session(id))
    #expect(session.agent == harness.agent)
    #expect(session.status == .needsInput)
    #expect(session.cwd == "/tmp/e2e-project")
    #expect(state.waitingCount == 1)
    #expect(state.startedWaiting == [id])
  }

  @Test func messageOnlyWhileNeedingInputAndMissingFieldsAreKept() async throws {
    app.post(event("s", .needsInput, cwd: "/tmp/a", title: "Title", message: "Approve?"))
    var session = try #require(
      try await app.waitForState { $0.session("claude:s") != nil }.session("claude:s"))
    #expect(session.message == "Approve?")
    #expect(session.title == "Title")

    app.post(event("s", .working, at: 1, message: "ignored"))
    session = try #require(
      try await app.waitForState { $0.session("claude:s")?.status == .working }
        .session("claude:s"))
    #expect(session.message == nil)
    #expect(session.title == "Title")
    #expect(session.cwd == "/tmp/a")
  }

  @Test func olderEventsAreIgnored() async throws {
    app.post(event("s", .working, at: 2))
    try await app.waitForState { $0.session("claude:s")?.status == .working }
    let state = try await app.postIgnored(event("s", .needsInput, at: 1))
    #expect(state.session("claude:s")?.status == .working)
    #expect(state.waitingCount == 0)
  }

  @Test func endedSessionsStayEnded() async throws {
    app.post(event("s", .working))
    try await app.waitForState { $0.session("claude:s") != nil }
    app.post(event("s", .ended, at: 2))
    try await app.waitForState { $0.session("claude:s") == nil }

    // Sent before the end, arriving after it (each hook is its own process).
    var state = try await app.postIgnored(event("s", .needsInput, at: 1))
    #expect(state.session("claude:s") == nil)

    app.post(event("s", .idle, at: 3))
    state = try await app.waitForState { $0.session("claude:s") != nil }
    #expect(state.session("claude:s")?.status == .idle)
  }

  @Test func newSessionInSameProcessReplacesOld() async throws {
    let agent = try StandInProcess()
    app.post(event("old", .needsInput, process: agent.wire))
    try await app.waitForState { $0.session("claude:old") != nil }

    // `/clear`: the same process, a new session ID.
    app.post(event("new", .idle, at: 1, process: agent.wire))
    let state = try await app.waitForState { $0.session("claude:new") != nil }
    #expect(state.session("claude:old") == nil)

    // Another agent's session with that process doesn't replace it.
    app.post(event("other", .idle, at: 2, agent: "codex", process: agent.wire))
    let after = try await app.waitForState { $0.session("codex:other") != nil }
    #expect(after.session("claude:new") != nil)
  }

  @Test func backgroundForkEndsItsSource() async throws {
    let agentView = try StandInProcess()
    app.post(event("source", .idle, process: agentView.wire))
    try await app.waitForState { $0.session("claude:source") != nil }

    // ← forks the session into another process; the interactive one stays on as the agent view.
    let daemon = try StandInProcess()
    let fork = WireDetails(hookEventName: "UserPromptSubmit", forkedFrom: "source")
    app.post(event("fork", .working, at: 1, process: daemon.wire, details: fork))
    var state = try await app.waitForState { $0.session("claude:fork") != nil }
    #expect(state.session("claude:source") == nil)

    // Sent before the fork, arriving after it.
    state = try await app.postIgnored(event("source", .needsInput, at: 0.5))
    #expect(state.session("claude:source") == nil)

    // Only the fork's first event ends it, so resuming the source later sticks.
    app.post(event("source", .idle, at: 2, process: agentView.wire))
    try await app.waitForState { $0.session("claude:source") != nil }
    app.post(event("fork", .needsInput, at: 3, process: daemon.wire, details: fork))
    state = try await app.waitForState { $0.session("claude:fork")?.status == .needsInput }
    #expect(state.session("claude:source") != nil)
  }

  @Test func guessedLocationOnlyFillsIn() async throws {
    let agent = try StandInProcess()
    let first = WireTerminal(tty: "/dev/ttys901", environment: [:])
    let guessed = WireTerminal(tty: "/dev/ttys902", environment: [:])
    let later = WireTerminal(tty: "/dev/ttys903", environment: [:])
    let guess = WireDetails(hookEventName: "UserPromptSubmit", locationIsGuess: true)

    app.post(event("a", .working, agent: "codex", terminal: first, process: agent.wire))
    try await app.waitForState { $0.session("codex:a") != nil }

    // A guess with a's process doesn't remove a, and fills in b, which has no location.
    app.post(
      event(
        "b", .working, at: 1, agent: "codex", terminal: guessed, process: agent.wire,
        details: guess))
    var state = try await app.waitForState { $0.session("codex:b") != nil }
    #expect(state.session("codex:a") != nil)
    #expect(state.session("codex:b")?.terminal == guessed)
    #expect(state.session("codex:b")?.process == agent.wire)

    // Once b has a location, a later guess doesn't change it.
    app.post(event("b", .needsInput, at: 2, agent: "codex", terminal: later, details: guess))
    state = try await app.waitForState { $0.session("codex:b")?.status == .needsInput }
    #expect(state.session("codex:b")?.terminal == guessed)
  }

  @Test func sessionsOfExitedProcessesArePruned() async throws {
    let agent = try StandInProcess()
    app.post(event("s", .working, process: agent.wire))
    try await app.waitForState { $0.session("claude:s") != nil }
    agent.kill()
    // Test mode prunes every second.
    try await app.waitForState(timeout: 5) { $0.session("claude:s") == nil }
  }

  @Test func menuOrder() async throws {
    app.post(event("working", .working, at: 1))
    app.post(event("waitingLonger", .needsInput, at: 2))
    app.post(event("idle", .idle, at: 3))
    app.post(event("waitingShorter", .needsInput, at: 4))
    let state = try await app.waitForState { $0.sorted.count == 4 }
    #expect(
      state.sorted.map(\.id) == [
        "claude:waitingLonger", "claude:waitingShorter", "claude:idle", "claude:working",
      ])
    #expect(state.waitingCount == 2)
  }

  @Test func alertsOncePerWait() async throws {
    app.post(event("s", .needsInput, at: 1))
    app.post(event("s", .needsInput, at: 2, message: "again"))
    app.post(event("s", .working, at: 3))
    app.post(event("s", .needsInput, at: 4))
    let state = try await app.waitForState { $0.session("claude:s")?.lastUpdated == start + 4 }
    #expect(state.startedWaiting == ["claude:s", "claude:s"])
  }

  @Test func sessionsSurviveAQuickRelaunch() async throws {
    app.post(event("kept", .needsInput, cwd: "/tmp/kept", message: "Approve?"))
    try await app.waitForState { $0.session("claude:kept") != nil }
    try await app.quit()
    #expect(FileManager.default.fileExists(atPath: app.sessionsURL.path))

    try await app.launch()
    let session = try #require(app.state?.session("claude:kept"))
    #expect(session.status == .needsInput)
    #expect(session.message == "Approve?")
    #expect(!FileManager.default.fileExists(atPath: app.sessionsURL.path))
  }

  @Test func staleSnapshotIsNotRestored() async throws {
    try await app.quit()
    let session: [String: Any] = [
      "id": "claude:stale", "agent": "claude", "status": "idle",
      "lastUpdated": Date().timeIntervalSinceReferenceDate - 200,
    ]
    try writeJSON(
      [
        "savedAt": Date().timeIntervalSinceReferenceDate - 3 * 60,
        "sessions": ["claude:stale": session],
      ], to: app.sessionsURL)

    try await app.launch()
    #expect(app.state?.session("claude:stale") == nil)
    #expect(!FileManager.default.fileExists(atPath: app.sessionsURL.path))
  }
}
