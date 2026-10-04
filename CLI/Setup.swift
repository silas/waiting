import Foundation

/// `waiting setup <agent>`: installs the hooks that run `waiting hook <agent>`.
/// `waiting setup vscode`: installs the extension that lets the app focus VS Code terminals.
func runSetup(_ arguments: ArraySlice<String>) {
  switch arguments.first {
  case "claude":
    setupClaude()
  case "vscode":
    setupVSCode()
  default:
    fail(usage)
  }
}

/// The command a harness should run for hook events, using this executable's absolute path.
func hookCommand(agent: String) -> String {
  guard let url = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
    fail("could not determine the path of the waiting executable")
  }
  return "\(shellQuoted(url.path)) hook \(agent)"
}

private func shellQuoted(_ string: String) -> String {
  let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
  if string.unicodeScalars.allSatisfy(safe.contains) {
    return string
  }
  return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
