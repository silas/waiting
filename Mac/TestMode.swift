import Foundation

/// The e2e tests (`E2E/`) run a Debug build of the app with `WAITING_E2E_DIR` set. It then runs
/// beside the user's own copy without touching it: it listens on the tests' notification name
/// (`WAITING_NOTIFICATION_NAME`, which the CLI posts to), keeps its saved sessions in that
/// directory, shows no menu bar icon, onboarding or alerts, registers no shortcuts, runs no
/// AppleScript and doesn't check for updates. After every change it writes its sessions to
/// `state.json` there for the tests to read. Compiled out of Release builds.
enum TestMode {
  #if DEBUG
    static let directory: URL? = ProcessInfo.processInfo.environment["WAITING_E2E_DIR"].flatMap {
      $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory)
    }
  #else
    static let directory: URL? = nil
  #endif

  static var isEnabled: Bool { directory != nil }

  static var notificationName: Notification.Name {
    guard isEnabled, let name = ProcessInfo.processInfo.environment["WAITING_NOTIFICATION_NAME"],
      !name.isEmpty
    else { return AgentEvent.notificationName }
    return Notification.Name(name)
  }

  /// IDs of sessions that `SessionStore.onStartWaiting` was called for, in order.
  private static var startedWaiting: [String] = []

  static func recordStartedWaiting(_ session: Session, in store: SessionStore) {
    startedWaiting.append(session.id)
    dump(store)
  }

  private struct State: Encodable {
    let sorted: [Session]
    let waitingCount: Int
    let startedWaiting: [String]
  }

  /// Writes the store's sessions, in menu order, to `state.json`.
  static func dump(_ store: SessionStore) {
    guard let directory else { return }
    let state = State(
      sorted: store.sorted, waitingCount: store.waitingCount, startedWaiting: startedWaiting)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: directory.appending(path: "state.json"), options: .atomic)
  }
}
