import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifiers (`cmdKey`, `optionKey`, …), as `RegisterEventHotKey` wants them.
struct Shortcut: Codable, Equatable {
  /// A `kVK_*` virtual key code.
  let keyCode: Int
  let modifiers: Int
  /// The key as shown to the user, captured when the shortcut was recorded.
  let key: String

  init(keyCode: Int, modifiers: Int, key: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.key = key
  }

  init(event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers = 0
    if flags.contains(.control) { modifiers |= controlKey }
    if flags.contains(.option) { modifiers |= optionKey }
    if flags.contains(.shift) { modifiers |= shiftKey }
    if flags.contains(.command) { modifiers |= cmdKey }
    let keyCode = Int(event.keyCode)
    self.init(
      keyCode: keyCode,
      modifiers: modifiers,
      key: Self.specialKeys[keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    )
  }

  /// Global shortcuts need ⌃, ⌥ or ⌘ so they don't swallow ordinary typing. Function keys are exempt.
  var isValid: Bool {
    modifiers & (controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(keyCode)
  }

  var displayString: String {
    var string = ""
    if modifiers & controlKey != 0 { string += "⌃" }
    if modifiers & optionKey != 0 { string += "⌥" }
    if modifiers & shiftKey != 0 { string += "⇧" }
    if modifiers & cmdKey != 0 { string += "⌘" }
    return string + key
  }

  private static let functionKeys: Set<Int> = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
  ]

  private static let specialKeys: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
    kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]
}
