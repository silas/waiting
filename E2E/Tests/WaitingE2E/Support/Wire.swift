import Foundation

// The wire format, mirrored rather than shared with `Shared/AgentEvent.swift`, so a change to it
// that would break a running app or an installed CLI of another version fails these tests.

enum WireState: String, Codable, Sendable {
  case idle
  case working
  case needsInput
  case ended
}

struct WireProcess: Codable, Equatable, Sendable {
  let pid: Int32
  let startTime: Double
}

struct WireTerminal: Codable, Equatable, Sendable {
  var bundleID: String?
  var tty: String?
  var environment: [String: String]
}

/// A harness's extras (`AgentEvent.claude`, `.codex`, …).
struct WireDetails: Codable, Equatable, Sendable {
  let hookEventName: String
  var locationIsGuess: Bool?
  var forkedFrom: String?
}

/// An `AgentEvent`, as the CLI posts it and the app reads it.
struct WireEvent: Codable, Sendable {
  var agent: String
  var sessionID: String
  var state: WireState
  var cwd: String?
  var title: String?
  var message: String?
  var terminal: WireTerminal?
  var process: WireProcess?
  var timestamp: Date
  /// The extras under the key named after `agent`.
  var details: WireDetails?

  init(
    agent: String, sessionID: String, state: WireState, cwd: String? = nil, title: String? = nil,
    message: String? = nil, terminal: WireTerminal? = nil, process: WireProcess? = nil,
    timestamp: Date = Date(), details: WireDetails? = nil
  ) {
    self.agent = agent
    self.sessionID = sessionID
    self.state = state
    self.cwd = cwd
    self.title = title
    self.message = message
    self.terminal = terminal
    self.process = process
    self.timestamp = timestamp
    self.details = details
  }

  private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    agent = try container.decode(String.self, forKey: Key("agent"))
    sessionID = try container.decode(String.self, forKey: Key("sessionID"))
    state = try container.decode(WireState.self, forKey: Key("state"))
    cwd = try container.decodeIfPresent(String.self, forKey: Key("cwd"))
    title = try container.decodeIfPresent(String.self, forKey: Key("title"))
    message = try container.decodeIfPresent(String.self, forKey: Key("message"))
    terminal = try container.decodeIfPresent(WireTerminal.self, forKey: Key("terminal"))
    process = try container.decodeIfPresent(WireProcess.self, forKey: Key("process"))
    timestamp = try container.decode(Date.self, forKey: Key("timestamp"))
    details = try container.decodeIfPresent(WireDetails.self, forKey: Key(agent))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(agent, forKey: Key("agent"))
    try container.encode(sessionID, forKey: Key("sessionID"))
    try container.encode(state, forKey: Key("state"))
    try container.encodeIfPresent(cwd, forKey: Key("cwd"))
    try container.encodeIfPresent(title, forKey: Key("title"))
    try container.encodeIfPresent(message, forKey: Key("message"))
    try container.encodeIfPresent(terminal, forKey: Key("terminal"))
    try container.encodeIfPresent(process, forKey: Key("process"))
    try container.encode(timestamp, forKey: Key("timestamp"))
    try container.encodeIfPresent(details, forKey: Key(agent))
  }
}

/// A session as the app keeps it (`Session`).
struct AppSession: Codable, Sendable {
  let id: String
  let agent: String
  let status: WireState
  var cwd: String?
  var title: String?
  var message: String?
  var terminal: WireTerminal?
  var process: WireProcess?
  let lastUpdated: Date
}

/// The app's `state.json` in test mode (`Mac/TestMode.swift`).
struct AppState: Decodable, Sendable {
  /// In menu order.
  let sorted: [AppSession]
  let waitingCount: Int
  /// Sessions `onStartWaiting` was called for, in order.
  let startedWaiting: [String]

  func session(_ id: String) -> AppSession? {
    sorted.first { $0.id == id }
  }
}
