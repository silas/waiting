import Foundation

/// The user's login shell, for environment variables set in their shell profile. An app opened
/// from Finder or at login doesn't inherit those, unlike a command run in a terminal.
nonisolated enum LoginShell {
  enum Lookup: Equatable, Sendable {
    case set(String)
    case unset
    /// The shell failed or took over 5s, so the value is unknown.
    case failed
  }

  /// The exported value of `name` in an interactive login shell, so it reads the same profile
  /// files as a terminal. Blocks, so call it off the main actor.
  static func variable(_ name: String) -> Lookup {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    // Profiles can print their own output, so find the value between markers.
    let marker = "__waiting_\(UUID().uuidString)__"
    let command = "echo \(marker); printenv \(name); echo \(marker)"
    let output = run([shell, "-l", "-i", "-c", command], timeout: 5) {
      $0.components(separatedBy: marker).count >= 3
    }
    let parts = output.components(separatedBy: marker)
    guard parts.count >= 3 else { return .failed }
    let value = parts[1].trimmingCharacters(in: .newlines)
    return value.isEmpty ? .unset : .set(value)
  }

  /// Runs `arguments` in its own process group and returns its stdout so far, once `isComplete`
  /// is true for it, stdout closes or `timeout` passes. Then the whole group is killed, so nothing
  /// it started is left running. (`Process` can't set the process group, and an interactive shell
  /// ignores the SIGTERM sent by `Process.terminate`.)
  ///
  /// It disclaims responsibility for the process, so if the user's profile touches something
  /// privacy-protected (say, a file in ~/Documents), macOS doesn't ask on Waiting's behalf.
  private static func run(
    _ arguments: [String], timeout: TimeInterval, until isComplete: (String) -> Bool
  ) -> String {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return "" }
    let (readEnd, writeEnd) = (fds[0], fds[1])
    defer { close(readEnd) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own process group, only the descriptors set up above, and default signal handling.
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
          | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var signals = sigset_t()
    sigfillset(&signals)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    disclaimResponsibility(&attributes)

    let argv = arguments.map { strdup($0) } + [nil]
    defer {
      for argument in argv { free(argument) }
    }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environ)
    close(writeEnd)
    guard spawned == 0 else { return "" }

    let deadline = Date.now.addingTimeInterval(timeout)
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !isComplete(String(decoding: output, as: UTF8.self)) {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(remaining * 1000) + 1)
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { break }
      let count = read(readEnd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      output.append(contentsOf: buffer[..<count])
    }

    kill(-pid, SIGKILL)
    waitpid(pid, nil, 0)
    return String(decoding: output, as: UTF8.self)
  }

  /// `responsibility_spawnattrs_setdisclaim`, which isn't in the SDK, so it's looked up at run
  /// time. LLDB and Chromium use it so that what a child process does is attributed to
  /// the child for privacy (TCC) purposes, not to the app that spawned it.
  private static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
        "responsibility_spawnattrs_setdisclaim")
    else { return }
    _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
  }
}
