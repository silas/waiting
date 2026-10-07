import Foundation

/// Receives the events posted under a notification name, by running `Listener` (distributed
/// notifications need a running run loop, which the test runner doesn't have).
final class EventListener: @unchecked Sendable {
  let notificationName: String
  private let process = Process()
  private let lock = NSLock()
  private var buffer = Data()
  private var lines: [String] = []
  private var isReady = false

  init(notificationName: String = "dev.waiting.e2e.\(UUID().uuidString)") throws {
    self.notificationName = notificationName
    let output = Pipe()
    process.executableURL = Build.listener
    process.arguments = [notificationName]
    process.standardOutput = output
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.receive(handle.availableData)
    }
    try process.run()

    let deadline = Date().addingTimeInterval(10)
    while !lock.withLock({ isReady }) {
      guard Date() < deadline, process.isRunning else {
        throw TimeoutError(description: "Listener didn't start")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  deinit {
    process.terminate()
  }

  private func receive(_ data: Data) {
    lock.withLock {
      buffer.append(data)
      while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...newline)
        if line == "ready" {
          isReady = true
        } else {
          lines.append(line)
        }
      }
    }
  }

  /// The next event received, waiting up to `timeout` for it.
  func next(timeout: TimeInterval = 5) async throws -> WireEvent {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let line: String? = lock.withLock { lines.isEmpty ? nil : lines.removeFirst() }
      if let line { return try JSONDecoder().decode(WireEvent.self, from: Data(line.utf8)) }
      guard Date() < deadline else {
        throw TimeoutError(description: "no event posted to \(notificationName) in \(timeout)s")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Events received until one matches `last` (included).
  func events(through last: (WireEvent) -> Bool, timeout: TimeInterval = 10) async throws
    -> [WireEvent]
  {
    var events: [WireEvent] = []
    while true {
      let event = try await next(timeout: timeout)
      events.append(event)
      if last(event) { return events }
    }
  }
}
