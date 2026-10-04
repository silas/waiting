import Foundation

/// Runs AppleScript source, compiling each distinct script once.
enum AppleScriptRunner {
  /// Scripts that embed a tab key or directory are new source each time, so the cache is emptied
  /// when it fills up. What it's for is the focus queries, which are polled with fixed source.
  private static let cacheLimit = 32
  private static var scripts: [String: NSAppleScript] = [:]

  /// The script's string result, or nil on any error (including a denied Automation permission).
  static func run(_ source: String) -> String? {
    execute(source)?.stringValue
  }

  /// The script's list result as strings, or nil on any error.
  static func runList(_ source: String) -> [String]? {
    guard let result = execute(source) else { return nil }
    guard result.descriptorType == typeAEList else { return result.stringValue.map { [$0] } }
    return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }
  }

  private static func execute(_ source: String) -> NSAppleEventDescriptor? {
    let script: NSAppleScript
    if let cached = scripts[source] {
      script = cached
    } else {
      guard let compiled = NSAppleScript(source: source) else { return nil }
      if scripts.count >= cacheLimit {
        scripts.removeAll()
      }
      scripts[source] = compiled
      script = compiled
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard error == nil else { return nil }
    return result
  }
}
