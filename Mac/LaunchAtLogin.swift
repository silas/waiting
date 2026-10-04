import Foundation
import Observation
import ServiceManagement

/// Registers the app as a login item with `SMAppService`. The system owns the state (the user can
/// also change it in System Settings > General > Login Items), so it's reread rather than stored.
@Observable
final class LaunchAtLogin {
  private(set) var status = SMAppService.mainApp.status
  private(set) var error: String?

  var isEnabled: Bool {
    get { status == .enabled || status == .requiresApproval }
    set {
      error = nil
      do {
        if newValue {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        self.error = error.localizedDescription
      }
      refresh()
    }
  }

  /// Starts at login by default: registers once, on first launch, so turning it off sticks.
  /// Debug builds skip this, so a development build isn't added to Login Items by accident. So does
  /// a copy on a disk image or translocated, whose path goes away: it registers on the first launch
  /// after the app is moved.
  static func registerOnFirstLaunch() {
    #if !DEBUG
      let key = "launchAtLogin.registeredByDefault"
      guard !UserDefaults.standard.bool(forKey: key), !WaitingCLI.isTemporaryLocation else {
        return
      }
      UserDefaults.standard.set(true, forKey: key)
      try? SMAppService.mainApp.register()
    #endif
  }

  func refresh() {
    status = SMAppService.mainApp.status
  }
}
