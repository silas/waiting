import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that shows an action's shortcut and records a new one when clicked.
/// Esc cancels recording; the clear button removes the shortcut.
struct ShortcutRecorder: View {
  let action: ShortcutAction
  let settings: ShortcutSettings

  @State private var monitor: Any?

  private var isRecording: Bool { settings.recording == action }

  var body: some View {
    HStack(spacing: 4) {
      Button {
        isRecording ? stop() : start()
      } label: {
        Text(isRecording ? "Type shortcut…" : settings.bindings[action]?.displayString ?? "None")
          .frame(minWidth: 110)
      }
      if settings.bindings[action] != nil, !isRecording {
        Button("Clear", systemImage: "xmark.circle.fill") {
          settings.set(nil, for: action)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
    }
    .onDisappear { stop() }
    // Another recorder started recording: drop this one's monitor, or it would keep capturing
    // keystrokes for this action.
    .onChange(of: isRecording) { _, isRecording in
      if !isRecording { removeMonitor() }
    }
  }

  private func start() {
    removeMonitor()
    settings.recording = action
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == kVK_Escape {
        stop()
        return nil
      }
      let shortcut = Shortcut(event: event)
      guard shortcut.isValid else {
        NSSound.beep()
        return nil
      }
      settings.set(shortcut, for: action)
      stop()
      return nil
    }
  }

  private func stop() {
    removeMonitor()
    if isRecording {
      settings.recording = nil
    }
  }

  private func removeMonitor() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
  }
}
