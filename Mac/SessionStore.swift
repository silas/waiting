import AppKit
import Observation

/// Tracks the status of each agent session from events sent by the `waiting` CLI.
/// State lives in memory. It's saved on quit and restored only by a quick relaunch (such as an
/// update): events sent while the app isn't running are lost, so an older snapshot can't be trusted.
@Observable final class SessionStore {
  /// How soon after quitting the app must relaunch for the saved sessions to be restored.
  private static let restoreWindow: TimeInterval = 2 * 60
  private static let pruneInterval: TimeInterval = TestMode.isEnabled ? 1 : 15
  /// How long an ended session's events are still ignored for (see `ended`).
  private static let endedGracePeriod: TimeInterval = 60

  private(set) var sessions: [String: Session] = [:] {
    didSet {
      focus.tmuxServers = Set(sessions.values.compactMap { Tmux.Pane($0.terminal)?.server })
      TestMode.dump(self)
    }
  }

  let focus = FocusMonitor()

  /// When recently ended sessions ended. Each hook runs its own CLI process, so an event sent just
  /// before the end can arrive after it, and would otherwise bring the session back.
  @ObservationIgnored private var ended: [String: Date] = [:]

  /// Background forks whose first event has been applied (see `apply`), so a fork the user removed
  /// doesn't end its source again on its next prompt.
  @ObservationIgnored private var forks: Set<String> = []

  /// The session `show` last brought forward, so `showNext` can keep cycling when the focused tab
  /// can't be identified (terminals without an adapter, or Automation permission denied).
  @ObservationIgnored private var lastShownID: String?

  /// The number of sessions that need input. Sessions in the focused tab are marked seen right
  /// away (see `markFocusedSeen`), so this never includes the tab the user is looking at.
  var waitingCount: Int {
    sessions.values.count { $0.status == .needsInput }
  }

  /// Called when a session starts needing input and isn't in the focused tab.
  @ObservationIgnored var onStartWaiting: ((Session) -> Void)?

  /// The sessions in menu order (see `Session.menuOrder`).
  var sorted: [Session] {
    Session.menuOrder(sessions.values)
  }

  private let fileURL: URL

  init() {
    let directory =
      TestMode.directory ?? URL.applicationSupportDirectory.appending(path: "dev.waiting.mac")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appending(path: "sessions.json")
    load()
    // Sparkle quits normally to install an update, so this runs then too. After a crash nothing
    // is saved, and the app starts empty.
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.save()
      }
    }

    focus.onChange = { [weak self] in
      self?.markFocusedSeen()
    }
    markFocusedSeen()

    pruneExited()
    Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.pruneExited()
      }
    }

    DistributedNotificationCenter.default().addObserver(
      forName: TestMode.notificationName,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let payload = notification.object as? String,
        let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(payload.utf8))
      else { return }
      MainActor.assumeIsolated {
        self?.apply(event)
      }
    }
    // Tells the e2e tests it's listening.
    TestMode.dump(self)
  }

  func remove(_ session: Session) {
    sessions[session.id] = nil
  }

  var hasIdle: Bool {
    sessions.values.contains { $0.status == .idle }
  }

  /// Removes every idle session (including ones the user has seen).
  func clearIdle() {
    sessions = sessions.filter { $0.value.status != .idle }
  }

  /// Removes sessions whose agent process has exited without sending an end event, and forgets
  /// sessions that ended long enough ago that no late event can still arrive.
  private func pruneExited() {
    let cutoff = Date().addingTimeInterval(-Self.endedGracePeriod)
    ended = ended.filter { $0.value > cutoff }
    // One assignment, so `sessions` is saved once rather than once per removal.
    let running = sessions.filter { $0.value.process?.isRunning ?? true }
    if running.count != sessions.count {
      sessions = running
    }
  }

  /// Switches to the session's terminal tab and clears its needs-input indicator until the next
  /// event raises it again. Sessions whose tab or terminal is gone are removed, and return false.
  /// Only call it when the user asked: it runs scripts even while they're paused (see
  /// `AppleScriptRunner.isPaused`), since a paused script would look like the tab is gone.
  @discardableResult func show(_ session: Session) -> Bool {
    AppleScriptRunner.userInitiated {
      learnTabKey(session.id, userIsHere: false)
      guard let session = sessions[session.id] else { return false }
      // A session whose terminal isn't known yet (a Codex terminal UI that couldn't be told apart
      // from another in the same directory) is only marked seen.
      guard session.terminal == nil || TerminalAdapters.show(session) else {
        remove(session)
        return false
      }
      markSeen(session.id)
      lastShownID = session.id
      // Switching tabs within an already-frontmost terminal doesn't post an activation
      // notification.
      focus.refresh()
      return true
    }
  }

  /// Shows the session that has been waiting on the user the longest. When none are waiting,
  /// cycles through the menu order instead: the session after the one in the focused tab, or the
  /// first session if the focused tab isn't one of ours. Sessions that are gone, or whose terminal
  /// isn't known yet, are skipped.
  func showNext() {
    AppleScriptRunner.userInitiated {
      focus.refresh()
      while let next = nextSession(), !show(next) {}
    }
  }

  private func nextSession() -> Session? {
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    return Session.next(
      in: sorted, isFocused: focus.isFocused,
      // The ID first, since finding a tmux session's client runs tmux.
      wasLastShownHere: {
        $0.id == self.lastShownID && Tmux.outer($0)?.terminal?.bundleID == frontmost
      }
    )
  }

  /// Fills in `learnedTab` for sessions in terminals whose adapter has to work it out. For
  /// sessions in tmux, that's the terminal of the tmux client, which is only learned when the user
  /// is known to be there: the terminal's working directory is where tmux was started, not the
  /// session's, and finding the client runs tmux, which would otherwise happen on every event.
  private func learnTabKey(_ id: String, userIsHere: Bool) {
    guard let session = sessions[id],
      userIsHere || Tmux.Pane(session.terminal) == nil,
      let outer = Tmux.outer(session), outer.learnedTabKey == nil, let terminal = outer.terminal,
      let adapter = TerminalAdapters.adapter(for: terminal.bundleID),
      let key = adapter.learnTabKey(for: outer, userIsHere: userIsHere)
    else { return }
    sessions[id]?.learnedTab = Session.LearnedTab(key: key, terminal: terminal)
  }

  /// Clears the needs-input indicator of every session in the focused tab: the user has seen it.
  private func markFocusedSeen() {
    for session in sessions.values where session.status == .needsInput && focus.isFocused(session) {
      markSeen(session.id)
    }
  }

  /// Returns a needs-input session to idle until its next event.
  private func markSeen(_ id: String) {
    // One assignment, so `sessions` is saved once.
    guard var session = sessions[id], session.status == .needsInput else { return }
    session.status = .idle
    session.message = nil
    sessions[id] = session
  }

  private func apply(_ event: AgentEvent) {
    let id = "\(event.agent):\(event.sessionID)"

    // Ignore events that arrive after a newer one for the same session.
    if let existing = sessions[id], existing.lastUpdated > event.timestamp {
      return
    }
    if let endedAt = ended[id], endedAt >= event.timestamp {
      return
    }

    if event.state == .ended {
      sessions[id] = nil
      ended[id] = event.timestamp
      return
    }

    let previous = sessions[id]
    var session =
      previous
      ?? Session(id: id, agent: event.agent, status: event.state, lastUpdated: event.timestamp)
    session.status = event.state
    session.cwd = event.cwd ?? session.cwd
    session.title = event.title ?? session.title
    session.message = event.state == .needsInput ? event.message : nil
    // A guessed terminal and process may be another session's, so they only fill in a session
    // that has neither, and don't replace other sessions below.
    let isGuess = event.codex?.locationIsGuess == true
    if !isGuess || (session.terminal == nil && session.process == nil) {
      // A different terminal (e.g. resumed elsewhere) makes the learned tab key stale.
      session.terminal = event.terminal ?? session.terminal
      session.process = event.process ?? session.process
    }
    session.lastUpdated = event.timestamp
    // `/clear` and `/resume` give the same agent process a new session ID. The old ID's end event
    // may be lost (sent while the app wasn't running, say), so drop any session it left behind.
    // One assignment, so observers see a single change.
    var updated = sessions
    // A Claude Code session sent to the background (← or `/bg`) is forked into a new session ID in
    // another process. With ←, the interactive process lives on as the agent view and sends no end
    // event for the session it left. So the fork's first event ends that one, unless the source has
    // a newer event: it was resumed after the fork, and that event just arrived first.
    if previous == nil, let source = event.claude?.forkedFrom, forks.insert(id).inserted {
      let sourceID = "\(event.agent):\(source)"
      if (updated[sourceID]?.lastUpdated ?? .distantPast) <= event.timestamp {
        updated[sourceID] = nil
        // Keep a later end, so events sent before it still can't bring the source back.
        ended[sourceID] = max(ended[sourceID] ?? event.timestamp, event.timestamp)
      }
    }
    if let process = event.process, !isGuess {
      updated = updated.filter {
        $0.key == id || $0.value.agent != event.agent || $0.value.process != process
      }
    }
    updated[id] = session
    sessions = updated

    // A new session starting idle was just launched, and one that starts working again was just
    // prompted (or had a permission approved): either way, by typing into its tab.
    let userIsHere =
      previous.map { event.state == .working && $0.status != .working }
      ?? (event.state == .idle)
    learnTabKey(id, userIsHere: userIsHere)

    if event.state == .needsInput {
      // Check focus now so a session in the frontmost tab is marked seen before the icon renders.
      focus.refresh()
      markFocusedSeen()
      if previous?.status != .needsInput, let session = sessions[id], session.status == .needsInput
      {
        onStartWaiting?(session)
      }
    }
  }

  private struct Snapshot: Codable {
    let savedAt: Date
    let sessions: [String: Session]
  }

  /// Restores the sessions saved on quit, if the app quit recently. The file is deleted either way,
  /// so a snapshot is never restored twice.
  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    try? FileManager.default.removeItem(at: fileURL)
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.savedAt.timeIntervalSinceNow > -Self.restoreWindow
    else { return }
    sessions = snapshot.sessions
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(Snapshot(savedAt: Date(), sessions: sessions))
    else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
