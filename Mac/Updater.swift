import AppKit
import Observation
import Sparkle

/// Owns Sparkle's updater. The feed URL and public key are in `Mac/Info.plist`.
@Observable final class Updater: NSObject {
  private(set) var canCheckForUpdates = false

  @ObservationIgnored private var controller: SPUStandardUpdaterController!
  @ObservationIgnored private var observation: NSKeyValueObservation?

  override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: !TestMode.isEnabled, updaterDelegate: nil, userDriverDelegate: self)
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      let canCheck = updater.canCheckForUpdates
      MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
    }
  }

  var automaticallyChecksForUpdates: Bool {
    get {
      access(keyPath: \.automaticallyChecksForUpdates)
      return controller.updater.automaticallyChecksForUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyChecksForUpdates) {
        controller.updater.automaticallyChecksForUpdates = newValue
      }
    }
  }

  /// The app has no Dock icon, so it activates itself first or the update window would open
  /// behind the frontmost app.
  func checkForUpdates() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }
}

/// Gentle reminders keep a scheduled update alert from stealing focus, which Sparkle expects of
/// apps without a Dock icon.
extension Updater: SPUStandardUserDriverDelegate {
  var supportsGentleScheduledUpdateReminders: Bool { true }
}
