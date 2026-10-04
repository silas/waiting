import AppKit

/// The Waiting extension for VS Code and its forks (source in `VSCode/`). It's bundled as
/// `Waiting.app/Contents/Resources/waiting.vsix` and installed with each editor's own command-line tool.
nonisolated enum VSCodeExtension {
  static let id = "waitingdev.waiting"

  struct Editor: Sendable, Identifiable {
    let name: String
    let bundleID: String
    /// The editor's command-line tool in `Contents/Resources/app/bin`.
    let cli: String

    var id: String { bundleID }

    /// The command-line tool, or nil if the editor isn't installed.
    var cliURL: URL? {
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
      }
      let url = app.appending(path: "Contents/Resources/app/bin/\(cli)")
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
  }

  static let editors = [
    Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", cli: "code"),
    Editor(
      name: "Visual Studio Code - Insiders", bundleID: "com.microsoft.VSCodeInsiders",
      cli: "code-insiders"),
    Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", cli: "cursor"),
    Editor(name: "VSCodium", bundleID: "com.vscodium", cli: "codium"),
  ]

  enum InstallError: LocalizedError {
    case noBundledExtension
    case editorNotFound(String)
    case failed(String, String)

    var errorDescription: String? {
      switch self {
      case .noBundledExtension: "waiting.vsix was not found in Waiting.app"
      case .editorNotFound(let name): "\(name) is not installed"
      case .failed(let name, let output): "Installing into \(name) failed: \(output)"
      }
    }
  }

  /// `waiting.vsix` in the Waiting.app this executable belongs to. Works from both the app
  /// (`Contents/MacOS`) and the embedded CLI (`Contents/Helpers`).
  static var bundledVSIX: URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let url = executable.deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Resources/waiting.vsix")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Version of the bundled extension, read from the `package.json` inside the vsix.
  static func bundledVersion() -> String? {
    guard let vsix = bundledVSIX,
      let result = run(
        URL(filePath: "/usr/bin/unzip"), ["-p", vsix.path, "extension/package.json"]),
      result.status == 0,
      let package = try? JSONSerialization.jsonObject(with: Data(result.output.utf8))
        as? [String: Any]
    else { return nil }
    return package["version"] as? String
  }

  /// Version of the extension installed in this editor, or nil if it isn't installed (or the
  /// editor isn't).
  static func installedVersion(in editor: Editor) -> String? {
    guard let cli = editor.cliURL,
      let result = run(cli, ["--list-extensions", "--show-versions"]), result.status == 0
    else { return nil }
    let prefix = id + "@"
    return result.output.split(separator: "\n")
      .first { $0.lowercased().hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }

  /// Whether `installed` is older than `bundled`, comparing version components numerically.
  static func isOutdated(_ installed: String, comparedTo bundled: String) -> Bool {
    installed.compare(bundled, options: .numeric) == .orderedAscending
  }

  /// Installs (or reinstalls) the bundled extension into this editor. Open windows pick it up
  /// after a reload.
  static func install(in editor: Editor) throws {
    guard let vsix = bundledVSIX else { throw InstallError.noBundledExtension }
    guard let cli = editor.cliURL else { throw InstallError.editorNotFound(editor.name) }
    guard let result = run(cli, ["--install-extension", vsix.path, "--force"]) else {
      throw InstallError.failed(editor.name, "could not run \(cli.path)")
    }
    guard result.status == 0 else {
      let message =
        result.output.split(separator: "\n").last.map(String.init) ?? "exit status \(result.status)"
      throw InstallError.failed(editor.name, message)
    }
  }

  /// Runs a tool to completion, returning its exit status and combined output.
  private static func run(_ executable: URL, _ arguments: [String]) -> (
    status: Int32, output: String
  )? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return nil
    }
    // Read before waiting, so a full pipe can't block the tool.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
