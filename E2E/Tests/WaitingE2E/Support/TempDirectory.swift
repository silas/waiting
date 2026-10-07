import Foundation

/// A fresh directory, deleted when this is released. Resolved with `realpath`, since agents report
/// `/private/var/…` for `/var/…`.
final class TempDirectory: @unchecked Sendable {
  let url: URL

  init(_ name: String = "waiting-e2e") throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = URL(filePath: realPath(base.path) ?? base.path, directoryHint: .isDirectory)
  }

  func path(_ component: String) -> URL { url.appending(path: component) }

  /// Creates a subdirectory.
  func directory(_ component: String) throws -> URL {
    let url = path(component)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

func realPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(cString: resolved)
}

func writeJSON(_ object: Any, to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

func readJSON(_ url: URL) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}
