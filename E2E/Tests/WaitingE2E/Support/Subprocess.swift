import Foundation

struct ProcessResult {
  let status: Int32
  let stdout: Data
  let stderr: Data

  var output: String { String(decoding: stdout, as: UTF8.self) }
  var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

struct TimeoutError: Error, CustomStringConvertible {
  let description: String
}

enum Subprocess {
  /// A minimal environment, so nothing about the terminal or agent the tests run in leaks into
  /// what the CLI detects.
  static func minimalEnvironment(_ overrides: [String: String] = [:]) -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    var environment = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR"].reduce(into: [:]) {
      $0[$1] = inherited[$1]
    }
    environment.merge(overrides) { $1 }
    return environment
  }

  /// The tests' environment without the variables of an agent the tests might be running inside
  /// (Claude Code refuses to start nested in another session), or of Waiting itself.
  static func inheritedEnvironment(
    _ overrides: [String: String] = [:], keeping kept: Set<String> = []
  ) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { key, _ in
      kept.contains(key)
        || !["CLAUDE", "CODEX_", "WAITING_"].contains { key.hasPrefix($0) }
    }
    environment.merge(overrides) { $1 }
    return environment
  }

  /// Runs `executable` to completion, killing it after `timeout`.
  static func run(
    _ executable: URL, _ arguments: [String] = [], stdin: Data? = nil,
    environment: [String: String], directory: URL? = nil, timeout: TimeInterval = 30
  ) throws -> ProcessResult {
    // Files rather than pipes: tests run in parallel, so other tests' children inherit a pipe's
    // descriptors and keep it open, and its reader would never see the end.
    let files = try TempDirectory("waiting-e2e-io")
    let input = files.path("stdin")
    let output = files.path("stdout")
    let error = files.path("stderr")
    try (stdin ?? Data()).write(to: input)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: error.path, contents: nil)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    if let directory { process.currentDirectoryURL = directory }
    process.standardInput =
      stdin == nil ? FileHandle.nullDevice : try FileHandle(forReadingFrom: input)
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: error)
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if Date() > deadline {
        process.terminate()
        process.waitUntilExit()
        throw TimeoutError(
          description: "\(executable.lastPathComponent) timed out after \(timeout)s")
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    let stdout = try Data(contentsOf: output)
    let stderr = try Data(contentsOf: error)
    return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  /// The full path of a command on the tests' `PATH`, or nil.
  static func which(_ command: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":") {
      let url = URL(filePath: String(directory)).appending(path: command)
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
  }
}

/// A process that sleeps until it's killed, to stand in for an agent's process.
final class StandInProcess: @unchecked Sendable {
  let process = Process()

  init() throws {
    process.executableURL = URL(filePath: "/bin/sleep")
    process.arguments = ["600"]
    try process.run()
  }

  var pid: Int32 { process.processIdentifier }

  var wire: WireProcess { WireProcess(pid: pid, startTime: ProcessStartTime.of(pid) ?? 0) }

  func kill() {
    process.terminate()
    process.waitUntilExit()
  }

  deinit {
    if process.isRunning { kill() }
  }
}

enum ProcessStartTime {
  /// As `ProcessTable.startTime` computes it.
  static func of(_ pid: Int32) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid
    else { return nil }
    let time = info.kp_proc.p_starttime
    return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
  }
}
