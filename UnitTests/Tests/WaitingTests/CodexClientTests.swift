import Foundation
import Testing

@testable import WaitingCore

/// `CodexClient.choose`: which terminal UI shows a session run by Codex's app server.
@Suite("Codex client")
struct CodexClientTests {
  let now = Date(timeIntervalSince1970: 1_000_000)

  func candidate(
    _ pid: pid_t, ppid: pid_t = 1, arguments: [String] = ["codex"], directory: String? = "/repo",
    typedAgo: TimeInterval? = nil
  ) -> CodexClient.Candidate {
    CodexClient.Candidate(
      pid: pid, ppid: ppid, arguments: arguments, directory: directory,
      lastInput: typedAgo.map { now.addingTimeInterval(-$0) })
  }

  func choose(
    _ candidates: [CodexClient.Candidate], cwd: String? = "/repo", userJustTyped: Bool = false
  ) -> (pid: pid_t, isGuess: Bool)? {
    CodexClient.choose(
      from: candidates, sessionID: "s1", cwd: cwd, userJustTyped: userJustTyped, now: now)
  }

  @Test func sessionIDInArgumentsWins() {
    let result = choose([
      candidate(10), candidate(11, arguments: ["codex", "resume", "s1"], directory: "/other"),
    ])
    #expect(result?.pid == 11)
    #expect(result?.isGuess == false)
  }

  @Test func onlyOneInTheDirectory() {
    let result = choose([candidate(10), candidate(11, directory: "/other")])
    #expect(result?.pid == 10)
    #expect(result?.isGuess == false)
  }

  @Test func sessionIDNamedTwiceFallsBackToDirectory() {
    let resume = ["codex", "resume", "s1"]
    let result = choose([
      candidate(10, arguments: resume), candidate(11, arguments: resume, directory: "/other"),
    ])
    #expect(result?.pid == 10)
  }

  @Test func noneInTheDirectory() {
    #expect(choose([candidate(10, directory: "/other")], userJustTyped: true) == nil)
  }

  @Test func noCwdAndNoNameIsNil() {
    #expect(choose([candidate(10)], cwd: nil) == nil)
  }

  @Test func nodeWrapperIsDroppedForItsChild() {
    let wrapper = candidate(10, arguments: ["node", "/usr/lib/node_modules/@openai/codex/bin"])
    let result = choose([wrapper, candidate(11, ppid: 10)])
    #expect(result?.pid == 11)
  }

  @Test func severalInTheDirectoryWithoutTypingIsNil() {
    #expect(choose([candidate(10, typedAgo: 0.1), candidate(11, typedAgo: 5)]) == nil)
  }

  @Test func severalInTheDirectoryTakesTheLastTypedInAsAGuess() {
    let result = choose(
      [candidate(10, typedAgo: 2), candidate(11, typedAgo: 0.1), candidate(12)],
      userJustTyped: true)
    #expect(result?.pid == 11)
    #expect(result?.isGuess == true)
  }

  @Test func typingMoreThanThreeSecondsAgoIsNil() {
    #expect(
      choose([candidate(10, typedAgo: 3.5), candidate(11, typedAgo: 10)], userJustTyped: true)
        == nil)
  }

  @Test(arguments: [
    (["/opt/homebrew/bin/codex"], true),
    (["codex", "resume", "s1"], true),
    (["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"], true),
    (["/opt/homebrew/bin/codex", "app-server", "--managed-daemon"], false),
    (["/usr/bin/vim", "codex"], false),
    (["/usr/bin/codexx"], false),
    ([], false),
  ])
  func terminalUI(arguments: [String], expected: Bool) {
    #expect(CodexClient.isTerminalUI(arguments) == expected)
  }
}
