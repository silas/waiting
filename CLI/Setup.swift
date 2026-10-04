import Foundation

/// `waiting setup <agent>`: installs the hooks that run `waiting hook <agent>`.
/// `waiting setup vscode`: installs the extension that lets the app focus VS Code terminals.
func runSetup(_ arguments: ArraySlice<String>) {
  switch arguments.first {
  case "claude":
    setupAgent(.claude)
  case "codex":
    setupAgent(.codex)
  case "vscode":
    setupVSCode()
  default:
    fail(usage)
  }
}
