import Carbon.HIToolbox
import Foundation
import Observation

/// Something the user can bind a global shortcut to.
enum ShortcutAction: String, CaseIterable, Identifiable {
  /// The raw value predates the cycling behavior; it's kept so saved bindings still load.
  case showNext = "showOldestWaiting"
  case openMenu

  var id: String { rawValue }

  var title: String {
    switch self {
    case .showNext: "Jump to waiting or next session"
    case .openMenu: "Open menu"
    }
  }

  var defaultShortcut: Shortcut? {
    switch self {
    case .showNext:
      return Shortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey | cmdKey, key: "L")
    case .openMenu:
      return Shortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | shiftKey | cmdKey, key: "L")
    }
  }

  fileprivate var hotKeyID: UInt32 {
    UInt32(Self.allCases.firstIndex(of: self)! + 1)
  }

  fileprivate var defaultsKey: String {
    "shortcut.\(rawValue)"
  }
}

/// The user's global shortcuts: persisted to UserDefaults and kept registered with the system.
@Observable final class ShortcutSettings {
  private(set) var bindings: [ShortcutAction: Shortcut] = [:]

  /// Actions whose shortcut the system refused, usually because another app owns it.
  private(set) var unavailable: Set<ShortcutAction> = []

  /// The action whose shortcut is being recorded. Hot keys are suspended meanwhile so the
  /// recorder can see the keystroke.
  var recording: ShortcutAction? {
    didSet { registerAll() }
  }

  @ObservationIgnored private let hotKeys = HotKeys()

  init(perform: @escaping (ShortcutAction) -> Void) {
    for action in ShortcutAction.allCases {
      bindings[action] = Self.load(action)
    }
    hotKeys.onPress = { id in
      if let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == id }) {
        perform(action)
      }
    }
    registerAll()
  }

  /// Sets or clears (`nil`) the shortcut for `action`.
  func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
    bindings[action] = shortcut
    let data = try? JSONEncoder().encode(shortcut)
    UserDefaults.standard.set(data, forKey: action.defaultsKey)
    registerAll()
  }

  func restoreDefaults() {
    for action in ShortcutAction.allCases {
      UserDefaults.standard.removeObject(forKey: action.defaultsKey)
      bindings[action] = action.defaultShortcut
    }
    registerAll()
  }

  private func registerAll() {
    var unavailable: Set<ShortcutAction> = []
    for action in ShortcutAction.allCases {
      hotKeys.unregister(action.hotKeyID)
      guard recording == nil, !TestMode.isEnabled, let shortcut = bindings[action] else { continue }
      if !hotKeys.register(shortcut, id: action.hotKeyID) {
        unavailable.insert(action)
      }
    }
    if self.unavailable != unavailable {
      self.unavailable = unavailable
    }
  }

  /// A missing key means the default; a stored `null` means the user cleared it.
  private static func load(_ action: ShortcutAction) -> Shortcut? {
    guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else {
      return action.defaultShortcut
    }
    return (try? JSONDecoder().decode(Shortcut?.self, from: data)) ?? action.defaultShortcut
  }
}
