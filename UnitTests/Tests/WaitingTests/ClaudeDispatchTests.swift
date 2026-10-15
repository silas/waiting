import Foundation
import Testing

@testable import WaitingCore

/// `ClaudeAttach.dispatch`: how the daemon started a background session, read from its roster.
@Suite("Claude dispatch")
struct ClaudeDispatchTests {
  func roster(
    sessionID: String = "fork", source: String = "slash",
    resumed: String? = "/Users/me/.claude/projects/-repo/original.jsonl", fork: Bool? = true
  ) -> Data {
    var launch: [String: Any] = ["mode": "resume"]
    launch["sessionId"] = resumed
    launch["fork"] = fork
    let roster: [String: Any] = [
      "proto": 1,
      "workers": [
        "other": [
          "dispatch": ["sessionId": "other", "source": "spare", "launch": ["mode": "new"]]
        ],
        String(sessionID.prefix(8)): [
          "pid": 1, "dispatch": ["sessionId": sessionID, "source": source, "launch": launch],
        ],
      ],
    ]
    return try! JSONSerialization.data(withJSONObject: roster)
  }

  func dispatch(_ roster: Data, sessionID: String = "fork") -> ClaudeAttach.Dispatch? {
    ClaudeAttach.dispatch(sessionID: sessionID, roster: roster)
  }

  @Test func forkFromTranscriptPathGivesItsSessionID() {
    #expect(dispatch(roster()) == .init(forkedFrom: "original", isSpare: false))
  }

  @Test func forkFromSessionIDIsTakenAsIs() {
    #expect(dispatch(roster(resumed: "original"))?.forkedFrom == "original")
  }

  @Test func onlyForksHaveASource() {
    #expect(dispatch(roster(fork: false))?.forkedFrom == nil)
    #expect(dispatch(roster(fork: nil))?.forkedFrom == nil)
    // Resuming without a fork keeps the session ID.
    #expect(dispatch(roster(resumed: "fork"))?.forkedFrom == nil)
  }

  @Test func spares() {
    #expect(dispatch(roster(source: "spare", resumed: nil, fork: nil)) == .init(isSpare: true))
    #expect(dispatch(roster(), sessionID: "other") == .init(isSpare: true))
  }

  @Test func changedShapesOnlyLoseWhatTheyHold() throws {
    var root = try #require(JSONSerialization.jsonObject(with: roster()) as? [String: Any])
    var workers = try #require(root["workers"] as? [String: Any])
    // Other workers whose entries changed shape don't hide this one.
    workers["broken"] = "worker"
    workers["odd"] = ["dispatch": ["sessionId": 7, "source": ["spare"]]]
    root["workers"] = workers
    let mixed = try JSONSerialization.data(withJSONObject: root)
    #expect(dispatch(mixed) == .init(forkedFrom: "original", isSpare: false))

    // A changed field in this one loses only that field.
    var launch: [String: Any] = ["sessionId": "original", "fork": "yes"]
    var entry: [String: Any] = ["sessionId": "fork", "source": "spare", "launch": launch]
    func withEntry() throws -> Data {
      try JSONSerialization.data(withJSONObject: ["workers": ["fork": ["dispatch": entry]]])
    }
    #expect(dispatch(try withEntry()) == .init(isSpare: true))
    launch["fork"] = true
    entry["launch"] = launch
    entry["source"] = 1
    #expect(dispatch(try withEntry()) == .init(forkedFrom: "original", isSpare: false))
  }

  @Test func otherSessionsAndBadRostersGiveNil() {
    #expect(dispatch(roster(), sessionID: "unknown") == nil)
    #expect(dispatch(Data("{}".utf8)) == nil)
    #expect(dispatch(Data("nope".utf8)) == nil)
  }
}
