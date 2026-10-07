import AppKit
import Foundation

/// A Debug Waiting.app running in test mode (`Mac/TestMode.swift`): beside the user's own copy,
/// with its own notification name and data directory, and its sessions readable from `state.json`.
final class TestApp: @unchecked Sendable {
  let notificationName = "dev.waiting.e2e.app.\(UUID().uuidString)"
  let directory: TempDirectory
  private var process: Process?

  var stateURL: URL { directory.path("state.json") }
  var sessionsURL: URL { directory.path("sessions.json") }

  init() throws {
    directory = try TempDirectory("waiting-e2e-app")
  }

  deinit {
    if let process, process.isRunning {
      process.terminate()
    }
  }

  /// Launches the app and waits until it's receiving events.
  func launch() async throws {
    try? FileManager.default.removeItem(at: stateURL)
    let process = Process()
    process.executableURL = Build.appExecutable
    process.environment = Subprocess.minimalEnvironment([
      "WAITING_E2E_DIR": directory.url.path,
      "WAITING_NOTIFICATION_NAME": notificationName,
    ])
    process.standardOutput = FileHandle.nullDevice
    process.standardError = try FileHandle(forWritingTo: logURL())
    try process.run()
    self.process = process

    // The first state is written once it has subscribed. A session posted then is still the
    // surest sign that events get through.
    _ = try await waitForState(timeout: 15) { _ in true }
    let ping = "ping-\(UUID().uuidString)"
    post(WireEvent(agent: "e2e", sessionID: ping, state: .idle))
    _ = try await waitForState { $0.session("e2e:\(ping)") != nil }
    post(WireEvent(agent: "e2e", sessionID: ping, state: .ended))
    _ = try await waitForState { $0.session("e2e:\(ping)") == nil }
  }

  private func logURL() throws -> URL {
    let url = directory.path("app.log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return url
  }

  /// Quits the app the way the menu's Quit does, so it saves its sessions.
  func quit() async throws {
    guard let process else { return }
    NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning {
      guard Date() < deadline else {
        process.terminate()
        throw TimeoutError(description: "the app didn't quit")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    self.process = nil
  }

  func post(_ event: WireEvent) {
    let data = try! JSONEncoder().encode(event)
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(notificationName), object: String(decoding: data, as: UTF8.self),
      userInfo: nil, deliverImmediately: true)
  }

  var state: AppState? {
    (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
  }

  /// Waits for a state that satisfies `predicate`, and returns it.
  @discardableResult
  func waitForState(timeout: TimeInterval = 5, _ predicate: (AppState) -> Bool) async throws
    -> AppState
  {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let state, predicate(state) { return state }
      guard Date() < deadline else {
        let last = (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "none"
        throw TimeoutError(description: "the app's state never matched; last state: \(last)")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Posts `event`, which the app should ignore, then a sentinel session, and returns the state
  /// once the sentinel has arrived. Events from one sender arrive in order, so `event` has been
  /// handled by then. The sentinel is ended again before returning.
  @discardableResult
  func postIgnored(_ event: WireEvent) async throws -> AppState {
    post(event)
    let sentinel = "sentinel-\(UUID().uuidString)"
    post(WireEvent(agent: "e2e", sessionID: sentinel, state: .working))
    let state = try await waitForState { $0.session("e2e:\(sentinel)") != nil }
    post(WireEvent(agent: "e2e", sessionID: sentinel, state: .ended))
    try await waitForState { $0.session("e2e:\(sentinel)") == nil }
    return state
  }
}
