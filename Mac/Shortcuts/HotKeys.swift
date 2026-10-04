import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's `RegisterEventHotKey`, which needs no permissions.
final class HotKeys {
  /// Called with the ID of the hot key that was pressed.
  var onPress: ((UInt32) -> Void)?

  private var refs: [UInt32: EventHotKeyRef] = [:]

  init() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard let userData else { return OSStatus(eventNotHandledErr) }
        // Carbon delivers application events on the main thread.
        MainActor.assumeIsolated {
          Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().onPress?(id.id)
        }
        return noErr
      },
      1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil
    )
  }

  /// Registers `shortcut` under `id`, replacing anything registered under it before.
  /// Returns false if the system refused, usually because another app owns the combination.
  func register(_ shortcut: Shortcut, id: UInt32) -> Bool {
    unregister(id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
      EventHotKeyID(signature: OSType(0x5754_4E47), id: id),  // 'WTNG'
      GetApplicationEventTarget(), 0, &ref
    )
    guard status == noErr, let ref else { return false }
    refs[id] = ref
    return true
  }

  func unregister(_ id: UInt32) {
    if let ref = refs.removeValue(forKey: id) {
      UnregisterEventHotKey(ref)
    }
  }
}
