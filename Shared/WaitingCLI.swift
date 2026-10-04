import Foundation

/// The `waiting` command-line tool, which agent hooks run.
nonisolated enum WaitingCLI {
  /// In the CLI, this executable. In the app, the copy embedded at `Contents/Helpers/waiting`.
  static var url: URL? {
    let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
    guard bundle.pathExtension == "app" else {
      return Bundle.main.executableURL?.resolvingSymlinksInPath()
    }
    let url = bundle.appending(path: "Contents/Helpers/waiting")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  /// Whether the CLI is on a read-only volume: a mounted disk image, or the temporary copy macOS
  /// runs a downloaded app from until it's moved (App Translocation). Its path won't last, so
  /// hooks shouldn't point at it.
  static var isTemporaryLocation: Bool {
    guard let url,
      let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
    else { return false }
    return values.volumeIsReadOnly == true
  }

  /// The command a harness should run for hook events, using the CLI's absolute path.
  static func hookCommand(agent: String) -> String? {
    url.map { "\(shellQuoted($0.path)) hook \(agent)" }
  }

  static func shellQuoted(_ string: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
    if string.unicodeScalars.allSatisfy(safe.contains) {
      return string
    }
    return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
