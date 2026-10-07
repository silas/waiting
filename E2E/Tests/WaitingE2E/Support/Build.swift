import Foundation

/// The products under test, and the helper executables built with this package.
enum Build {
  /// This package's directory.
  static let packageDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

  /// `WAITING_APP`, else the repository's Debug build. Test mode is compiled out of Release builds.
  static let app: URL = {
    if let path = ProcessInfo.processInfo.environment["WAITING_APP"], !path.isEmpty {
      return URL(filePath: path, relativeTo: packageDirectory.deletingLastPathComponent())
        .standardizedFileURL
    }
    return packageDirectory.appending(path: "../build/Build/Products/Debug/Waiting.app")
      .standardizedFileURL
  }()

  static var cli: URL { app.appending(path: "Contents/Helpers/waiting") }
  static var appExecutable: URL { app.appending(path: "Contents/MacOS/Waiting") }

  /// The `Listener` executable, built next to the test bundle.
  static let listener: URL = {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let directory = bundle.map { URL(filePath: $0.bundlePath).deletingLastPathComponent() }
    return (directory ?? packageDirectory.appending(path: ".build/debug"))
      .appending(path: "Listener")
  }()

  /// The hook command `waiting setup` installs for an agent, as `WaitingCLI.hookCommand` writes it.
  static func hookCommand(agent: String) -> String {
    "\(shellQuoted(cli.resolvingSymlinksInPath().path)) hook \(agent)"
  }

  static func shellQuoted(_ string: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
    if string.unicodeScalars.allSatisfy(safe.contains) { return string }
    return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
