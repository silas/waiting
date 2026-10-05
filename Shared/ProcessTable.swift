import Foundation

/// Identifies a running process. The start time guards against the PID being reused.
nonisolated struct AgentProcess: Codable, Sendable, Hashable {
  let pid: Int32
  let startTime: Double

  /// Whether this exact process is still running.
  var isRunning: Bool {
    ProcessTable.info(pid).map { ProcessTable.startTime($0) == startTime } ?? false
  }
}

/// Reads the kernel process table via `sysctl`.
nonisolated enum ProcessTable {
  static func info(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid
    else {
      return nil
    }
    return info
  }

  /// Every process of the current user.
  static func userProcesses() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
    // Room for processes started in between.
    size += size / 8
    let stride = MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
    guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
    return Array(processes.prefix(size / stride))
  }

  /// The process and its ancestors, stopping before launchd.
  static func ancestors(of start: pid_t = getpid()) -> [pid_t] {
    var pids: [pid_t] = []
    var pid = start
    while pid > 1, pids.count < 64, let info = info(pid) {
      pids.append(pid)
      pid = info.kp_eproc.e_ppid
    }
    return pids
  }

  static func name(_ info: kinfo_proc) -> String {
    withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// The process's controlling terminal, e.g. `/dev/ttys003`, or nil if it has none.
  static func tty(_ info: kinfo_proc) -> String? {
    let dev = info.kp_eproc.e_tdev
    guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
    let path = "/dev/" + String(cString: name)
    return path == "/dev/??" ? nil : path
  }

  /// When input was last read from the terminal (its access time, as `w` uses for idle time).
  static func lastInput(tty: String) -> Date? {
    var info = stat()
    guard stat(tty, &info) == 0 else { return nil }
    let time = info.st_atimespec
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
  }

  /// Path of the process's executable.
  static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  /// The process's current working directory. Only readable for processes of the same user.
  static func currentDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// The process's environment, as it was when it started. Only readable for processes of the
  /// same user.
  static func environment(_ pid: pid_t) -> [String: String]? {
    commandLine(pid)?.environment
  }

  /// The process's arguments (starting with `argv[0]`) and environment, as they were when it
  /// started. Only readable for processes of the same user.
  static func commandLine(_ pid: pid_t) -> (arguments: [String], environment: [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
    else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

    // Layout: argc, the executable path, padding NULs, argc arguments, then the environment,
    // all NUL-terminated strings.
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    func nextString() -> String? {
      guard index < size, let end = buffer[index..<size].firstIndex(of: 0) else { return nil }
      defer { index = end + 1 }
      return String(decoding: buffer[index..<end], as: UTF8.self)
    }
    // Skip the executable path and its padding, then the arguments (which may be empty).
    _ = nextString()
    while index < size, buffer[index] == 0 {
      index += 1
    }
    var arguments: [String] = []
    for _ in 0..<argc {
      guard let argument = nextString() else { break }
      arguments.append(argument)
    }
    var environment: [String: String] = [:]
    while let entry = nextString(), !entry.isEmpty {
      guard let equals = entry.firstIndex(of: "=") else { continue }
      environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return (arguments, environment)
  }

  static func startTime(_ info: kinfo_proc) -> Double {
    let time = info.kp_proc.p_starttime
    return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
  }
}
