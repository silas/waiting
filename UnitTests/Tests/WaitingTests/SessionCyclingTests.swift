import Foundation
import Testing

@testable import WaitingCore

/// `Session.menuOrder` and `Session.next`: the menu's order and what the "Jump to waiting or next
/// session" shortcut shows. Tabs are told apart by tty.
@Suite("Session cycling")
struct SessionCyclingTests {
  /// A session updated `age` seconds ago, in the tab with `tty` (default: a tab of its own).
  func session(
    _ id: String, _ status: SessionState = .idle, age: TimeInterval = 0,
    tty: String? = nil
  ) -> Session {
    Session(
      id: id, agent: "claude", status: status, cwd: nil, title: nil, message: nil,
      terminal: TerminalLocation(
        bundleID: "com.example.term", tty: tty ?? "/dev/\(id)", environment: [:]),
      learnedTab: nil, process: nil, lastUpdated: Date(timeIntervalSince1970: 1_000_000 - age))
  }

  func withoutTerminal(_ session: Session) -> Session {
    var session = session
    session.terminal = nil
    return session
  }

  /// `Session.next` with the tab whose tty is `focused` focused, and `lastShown` last shown with
  /// its terminal frontmost.
  func next(_ sorted: [Session], focused: String? = nil, lastShown: String? = nil) -> String? {
    Session.next(
      in: sorted, isFocused: { focused != nil && $0.terminal?.tty == focused },
      wasLastShownHere: { $0.id == lastShown }
    )?.id
  }

  @Test func menuOrderPutsLongestWaitingFirstThenMostRecent() {
    let order = Session.menuOrder([
      session("old", age: 30), session("new", age: 10),
      session("waitedLong", .needsInput, age: 40), session("waitedShort", .needsInput, age: 5),
      session("working", .working, age: 20),
    ])
    #expect(order.map(\.id) == ["waitedLong", "waitedShort", "new", "working", "old"])
  }

  @Test func noSessions() {
    #expect(next([]) == nil)
  }

  @Test func waitingSessionWinsEvenWhenFocused() {
    let sorted = [session("w", .needsInput, tty: "/dev/a"), session("b")]
    #expect(next(sorted, focused: "/dev/a") == "w")
  }

  @Test func withoutCurrentSessionShowsTheFirst() {
    #expect(next([session("a"), session("b")]) == "a")
  }

  @Test func showsTheOneAfterTheFocusedOne() {
    #expect(next([session("a"), session("b"), session("c")], focused: "/dev/b") == "c")
  }

  @Test func wrapsAround() {
    #expect(next([session("a"), session("b"), session("c")], focused: "/dev/c") == "a")
  }

  @Test func skipsOthersInTheFocusedTab() {
    let sorted = [
      session("a", tty: "/dev/x"), session("b", tty: "/dev/x"), session("c", tty: "/dev/y"),
      session("d", tty: "/dev/x"),
    ]
    // a is current; b and d are in the same tab, so showing them wouldn't move.
    #expect(next(sorted, focused: "/dev/x") == "c")
    #expect(next(sorted, focused: "/dev/y") == "d")
  }

  @Test func allInTheFocusedTabStaysPut() {
    let sorted = [session("a", tty: "/dev/x"), session("b", tty: "/dev/x")]
    #expect(next(sorted, focused: "/dev/x") == "a")
  }

  @Test func continuesFromTheLastShownWhenNoTabIsFocused() {
    #expect(next([session("a"), session("b"), session("c")], lastShown: "b") == "c")
  }

  @Test func focusBeatsTheLastShown() {
    let sorted = [session("a"), session("b"), session("c")]
    #expect(next(sorted, focused: "/dev/a", lastShown: "b") == "b")
  }

  @Test func sessionsWithoutTerminalAreSkipped() {
    let sorted = [withoutTerminal(session("a")), session("b"), withoutTerminal(session("c"))]
    #expect(next(sorted) == "b")
    #expect(next(sorted, focused: "/dev/b") == "b")
    #expect(next(sorted, lastShown: "a") == "b")
  }

  @Test func onlySessionsWithoutTerminal() {
    #expect(next([withoutTerminal(session("a"))]) == nil)
  }
}
