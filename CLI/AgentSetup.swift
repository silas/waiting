import Foundation

/// Installs an agent's hooks (see `AgentHooks.install`).
func setupAgent(_ hooks: AgentHooks) {
  let settingsURL = hooks.settingsURL
  let result: AgentHooks.InstallResult
  do {
    result = try hooks.install()
  } catch {
    fail(error.localizedDescription)
  }

  switch result {
  case .alreadyInstalled:
    print("\(hooks.name) hooks are already installed in \(settingsURL.path)")
  case .installed(let backup):
    if let backup {
      print("Backed up \(settingsURL.path) to \(backup.lastPathComponent)")
    }
    print("Installed hooks for \(hooks.events.joined(separator: ", ")) in \(settingsURL.path)")
  }
  if hooks.status() == .untrusted {
    print("Open /hooks in \(hooks.name) and trust the Waiting hooks; until then it won't run them.")
  }
  if case .installed = result {
    print("Restart running \(hooks.name) sessions to pick them up.")
  }
}
