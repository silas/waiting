import Foundation
import Observation

/// Whether an agent is installed and has Waiting's hooks, for Settings.
@Observable final class AgentHooksStatus: Identifiable {
  let hooks: AgentHooks
  var id: String { hooks.agent }
  /// False until the first `refresh` finishes, which can take seconds (see `AgentHooks.configDirectory`).
  private(set) var isLoaded = false
  private(set) var isDetected = false
  /// False when the config variable couldn't be learned, so the default directory is a guess.
  private(set) var isConfigDirectoryKnown = true
  private(set) var status = AgentHooks.Status.notInstalled
  private(set) var isInstalling = false
  /// The app is on a disk image or translocated, so installing would point hooks at a path that
  /// goes away.
  private(set) var isTemporaryLocation = false
  private(set) var error: String?
  /// Set once hooks have been installed since launch. Running sessions don't pick them up.
  private(set) var needsRestart = false

  init(_ hooks: AgentHooks) {
    self.hooks = hooks
  }

  /// One per supported agent, in the order Settings lists them.
  static func all() -> [AgentHooksStatus] {
    [AgentHooksStatus(.claude), AgentHooksStatus(.codex)]
  }

  func refresh() async {
    (isConfigDirectoryKnown, isDetected, status, isTemporaryLocation) = await Self.load(hooks)
    isLoaded = true
  }

  func install() async {
    isInstalling = true
    error = nil
    do {
      if case .installed = try await Self.install(hooks) {
        needsRestart = true
      }
    } catch {
      self.error = error.localizedDescription
    }
    isInstalling = false
    await refresh()
  }

  @concurrent private static func load(_ hooks: AgentHooks) async -> (
    Bool, Bool, AgentHooks.Status, Bool
  ) {
    // First, so the others reuse its answer.
    let isKnown = hooks.configDirectoryLookup().isKnown
    return (isKnown, hooks.isDetected, hooks.status(), WaitingCLI.isTemporaryLocation)
  }

  @concurrent private static func install(_ hooks: AgentHooks) async throws
    -> AgentHooks.InstallResult
  {
    try hooks.install()
  }
}

extension [AgentHooksStatus] {
  func refresh() async {
    await withTaskGroup { group in
      for status in self {
        group.addTask { await status.refresh() }
      }
    }
  }
}
