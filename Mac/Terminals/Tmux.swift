import Foundation

/// tmux. Inside tmux, the CLI captures tmux's pane rather than the terminal tab showing it: its tty
/// is the pane's, and its bundle ID is whatever terminal started the tmux server. So sessions are
/// identified by their pane (from `TMUX` and `TMUX_PANE`), and the terminal is worked out live from
/// the tmux client showing that pane, the same way the CLI detects its own terminal. This follows a
/// tmux session when it's detached and reattached elsewhere, and works with any `TerminalAdapter`.
enum Tmux {
  /// A tmux server, identified by its socket. The PID tells when it has exited.
  struct Server: Hashable {
    let socket: String
    let pid: pid_t
  }

  /// A tmux pane, e.g. `%3`. Pane IDs are unique per server.
  struct Pane: Hashable {
    let server: Server
    let id: String

    /// The pane an agent runs in, or nil if it isn't running in tmux.
    init?(_ location: TerminalLocation?) {
      // `TMUX` is `<socket path>,<server pid>,<session index>`.
      guard let tmux = location?.environment["TMUX"], let id = location?.environment["TMUX_PANE"]
      else {
        return nil
      }
      let parts = tmux.split(separator: ",", omittingEmptySubsequences: false)
      guard parts.count >= 3, let pid = pid_t(parts[parts.count - 2]) else { return nil }
      self.init(server: Server(socket: parts.dropLast(2).joined(separator: ","), pid: pid), id: id)
    }

    init(server: Server, id: String) {
      self.server = server
      self.id = id
    }
  }

  /// A pane shown in the client's current window, and the terminal that client is running in.
  struct View: Hashable {
    let pane: Pane
    let terminal: TerminalLocation
  }

  enum Selection {
    /// The pane was made current in a client running in this terminal.
    case selected(TerminalLocation?)
    /// The pane (or its whole server) is gone.
    case notFound
    /// tmux couldn't be asked, or no client is attached to show the pane in.
    case failed
  }

  /// The session as seen from outside tmux: with the terminal of the client best placed to show
  /// its pane. Sessions not in tmux are returned as is. Nil if no client could show it.
  static func outer(_ session: Session) -> Session? {
    guard let pane = Pane(session.terminal) else { return session }
    guard let snapshot = snapshot(pane.server), let client = snapshot.bestClient(for: pane.id),
      let terminal = client.terminal
    else { return nil }
    var outer = session
    outer.terminal = terminal
    return outer
  }

  /// Makes the pane current in the client best placed to show it.
  static func select(_ pane: Pane) -> Selection {
    guard ProcessTable.info(pane.server.pid) != nil else { return .notFound }
    guard let snapshot = snapshot(pane.server) else { return .failed }
    guard snapshot.panes.contains(where: { $0.id == pane.id }) else { return .notFound }
    guard let client = snapshot.bestClient(for: pane.id),
      run(
        pane.server,
        [
          "switch-client", "-c", client.tty, "-t", pane.id, ";",
          "select-window", "-t", pane.id, ";",
          "select-pane", "-t", pane.id,
        ]) != nil
    else { return .failed }
    return .selected(client.terminal)
  }

  /// Panes shown in the current window of each client running in the app with this bundle ID.
  static func views(in bundleID: String, servers: Set<Server>) -> Set<View> {
    var views: Set<View> = []
    for server in servers {
      guard let snapshot = snapshot(server) else { continue }
      for client in snapshot.clients {
        guard let terminal = client.terminal, terminal.bundleID == bundleID else { continue }
        for pane in snapshot.panes where pane.isActive && pane.sessionID == client.sessionID {
          views.insert(View(pane: Pane(server: server, id: pane.id), terminal: terminal))
        }
      }
    }
    return views
  }

  // MARK: - Querying tmux

  private struct Snapshot {
    struct Client {
      let tty: String
      let sessionID: String
      /// When the client last had input, in seconds since 1970.
      let activity: Int
      let terminal: TerminalLocation?
    }

    /// A pane in one tmux session. Panes in grouped sessions are listed once per session.
    struct PaneEntry {
      let id: String
      let sessionID: String
      /// Whether this is the active pane in its session's current window.
      let isActive: Bool
    }

    let clients: [Client]
    let panes: [PaneEntry]

    /// A client already showing the pane, else one on the pane's tmux session, else any client;
    /// the most recently used of those.
    func bestClient(for paneID: String) -> Client? {
      let entries = panes.filter { $0.id == paneID }
      func rank(_ client: Client) -> Int {
        if entries.contains(where: { $0.sessionID == client.sessionID && $0.isActive }) { return 2 }
        if entries.contains(where: { $0.sessionID == client.sessionID }) { return 1 }
        return 0
      }
      return clients.max { (rank($0), $0.activity) < (rank($1), $1.activity) }
    }
  }

  private static func snapshot(_ server: Server) -> Snapshot? {
    guard
      let output = run(
        server,
        [
          "list-clients", "-F",
          "c\t#{client_tty}\t#{client_pid}\t#{session_id}\t#{client_activity}", ";",
          "list-panes", "-a", "-F",
          "p\t#{pane_id}\t#{session_id}\t#{window_active}\t#{pane_active}",
        ])
    else { return nil }

    var clients: [Snapshot.Client] = []
    var panes: [Snapshot.PaneEntry] = []
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 5 else { continue }
      switch fields[0] {
      case "c":
        guard let pid = pid_t(fields[2]) else { continue }
        clients.append(
          Snapshot.Client(
            tty: fields[1],
            sessionID: fields[3],
            activity: Int(fields[4]) ?? 0,
            terminal: clientTerminal(pid: pid, tty: fields[1])
          ))
      case "p":
        panes.append(
          Snapshot.PaneEntry(
            id: fields[1], sessionID: fields[2], isActive: fields[3] == "1" && fields[4] == "1"))
      default:
        continue
      }
    }
    return Snapshot(clients: clients, panes: panes)
  }

  /// Terminals of tmux clients, by PID and start time. A client's terminal doesn't change, and
  /// focus polling would otherwise detect it every second.
  private static var clientTerminals: [AgentProcess: TerminalLocation] = [:]

  /// The terminal a tmux client is running in, detected like the CLI detects its own.
  private static func clientTerminal(pid: pid_t, tty: String) -> TerminalLocation? {
    guard let info = ProcessTable.info(pid) else { return nil }
    let process = AgentProcess(pid: pid, startTime: ProcessTable.startTime(info))
    if let cached = clientTerminals[process] {
      return cached
    }
    guard
      var terminal = TerminalLocation.detect(
        pid: pid, environment: ProcessTable.environment(pid) ?? [:])
    else { return nil }
    terminal.tty = tty
    clientTerminals = clientTerminals.filter { $0.key.isRunning }
    clientTerminals[process] = terminal
    return terminal
  }

  /// Runs tmux commands against the server, returning stdout, or nil if tmux failed or hung.
  private static func run(_ server: Server, _ arguments: [String]) -> String? {
    // The server's own binary: the app may be launched without tmux on its PATH, and it's
    // guaranteed to speak the server's protocol.
    guard let tmux = ProcessTable.executablePath(server.pid) else { return nil }
    let process = Process()
    process.executableURL = URL(filePath: tmux)
    process.arguments = ["-S", server.socket] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    // Drain stdout while tmux runs, so output bigger than the pipe buffer can't block it.
    let result = OutputBuffer()
    let read = DispatchSemaphore(value: 0)
    let reader = output.fileHandleForReading
    DispatchQueue.global().async {
      result.data = reader.readDataToEndOfFile()
      read.signal()
    }
    // Called on the main actor, so don't let a wedged server hang the app.
    let deadline = DispatchTime.now() + 1
    guard read.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success
    else {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: result.data, as: UTF8.self)
  }

  /// Filled in by the background read in `run`, which waits for it before reading `data`.
  nonisolated private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
  }
}
