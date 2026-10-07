import Foundation
import Testing

/// Runs `waiting hook <agent>` with a harness's input and reads what it posts.
struct HookRunner {
  let harness: any Harness
  let listener: EventListener
  /// Added to the CLI's (minimal) environment.
  var environment: [String: String] = [:]

  init(_ harness: any Harness, environment: [String: String] = [:]) throws {
    self.harness = harness
    self.listener = try EventListener()
    self.environment = environment
  }

  /// Runs the hook with `input` as its stdin.
  @discardableResult
  func run(_ input: Any, environment extra: [String: String] = [:]) throws -> ProcessResult {
    let data =
      try (input as? Data) ?? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return try Subprocess.run(
      Build.cli, ["hook", harness.agent], stdin: data,
      environment: Subprocess.minimalEnvironment(
        environment.merging(extra) { $1 }.merging([
          "WAITING_NOTIFICATION_NAME": listener.notificationName
        ]) { $1 }))
  }

  /// Runs the hook and returns the event it posted.
  func event(_ input: Any, environment extra: [String: String] = [:]) async throws -> WireEvent {
    let result = try run(input, environment: extra)
    #expect(result.status == 0, "waiting hook failed: \(result.errorOutput)")
    return try await listener.next()
  }

  /// Runs the hook with an input it should drop, then with a sentinel input that posts, and
  /// checks the sentinel's event is the next one. Each hook is a separate post from a process that
  /// has exited, so they arrive in order.
  func expectDropped(
    _ input: Any, environment extra: [String: String] = [:],
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let result = try run(input, environment: extra)
    #expect(
      result.status == 0, "waiting hook failed: \(result.errorOutput)",
      sourceLocation: sourceLocation)
    let sentinel = "sentinel-\(UUID().uuidString)"
    try run(try #require(harness.input(for: .turnEnded, sessionID: sentinel, cwd: "/tmp")))
    let next = try await listener.next()
    #expect(
      next.sessionID == sentinel, "expected no event, got \(next)", sourceLocation: sourceLocation)
  }
}

/// Runs `waiting setup <agent>` against a config directory.
enum WaitingSetup {
  static func run(_ harness: any Harness, configDirectory: URL) throws -> ProcessResult {
    try Subprocess.run(
      Build.cli, ["setup", harness.agent],
      environment: Subprocess.minimalEnvironment([harness.configVariable: configDirectory.path]))
  }

  /// Installs the hooks, failing the test if setup fails.
  static func install(_ harness: any Harness, configDirectory: URL) throws {
    let result = try run(harness, configDirectory: configDirectory)
    try #require(result.status == 0, "waiting setup failed: \(result.errorOutput)")
  }
}
