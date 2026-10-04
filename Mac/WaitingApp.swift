import SwiftUI

@main struct WaitingApp: App {
  @State private var store: SessionStore
  @State private var shortcuts: ShortcutSettings
  @State private var agents = AgentHooksStatus.all()
  @State private var vscode: VSCodeExtensionStatus
  @State private var attention: AttentionSettings
  @State private var updater = Updater()
  @State private var launchAtLogin: LaunchAtLogin
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    // Before anything queries a terminal: the Automation prompt shouldn't cover onboarding.
    AppleScriptRunner.isPaused = !Onboarding.isCompleted
    let store = SessionStore()
    _store = State(initialValue: store)
    let attention = AttentionSettings()
    _attention = State(initialValue: attention)
    store.onStartWaiting = { session in
      attention.announce(session) {
        if let current = store.sessions[session.id] { store.show(current) }
      }
    }
    _shortcuts = State(
      initialValue: ShortcutSettings { action in
        switch action {
        case .showNext: store.showNext()
        case .openMenu: MenuBarList.open()
        }
      })
    let vscode = VSCodeExtensionStatus()
    _vscode = State(initialValue: vscode)
    Task { await vscode.updateInstalled() }
    LaunchAtLogin.registerOnFirstLaunch()
    _launchAtLogin = State(initialValue: LaunchAtLogin())
  }

  var body: some Scene {
    MenuBarExtra {
      ForEach(Array(store.sorted.enumerated()), id: \.element.id) { index, session in
        Button {
          store.show(session)
        } label: {
          Text(label(for: session))
          if let subtitle = subtitle(for: session) {
            // Shown as the item's subtitle, on a second line.
            Text(subtitle)
          }
        }
        .keyboardShortcut(shortcut(forItem: index, modifiers: .command))
        .modifierKeyAlternate(.option) {
          Button("Remove \(session.name)") {
            store.remove(session)
          }
          .keyboardShortcut(shortcut(forItem: index, modifiers: [.command, .option]))
        }
      }
      if store.hasIdle {
        Button("Clear Idle Sessions") {
          store.clearIdle()
        }
      }
      if !store.sessions.isEmpty {
        Divider()
      }
      SettingsButton()
      Button("Check for Updates…") {
        updater.checkForUpdates()
      }
      .disabled(!updater.canCheckForUpdates)
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      MenuBarLabel(
        count: store.waitingCount,
        showsCount: attention.showsCount,
        isPreviewingCount: attention.isPreviewingCount
      )
    }

    OnboardingWindow(
      launchAtLogin: launchAtLogin, agents: agents, vscode: vscode, attention: attention,
      shortcuts: shortcuts, updater: updater)

    Settings {
      SettingsView(
        launchAtLogin: launchAtLogin, shortcuts: shortcuts, agents: agents, vscode: vscode,
        attention: attention, updater: updater
      )
    }
  }

  /// 1 through 9, then 0, for the first ten sessions in the menu.
  private func shortcut(forItem index: Int, modifiers: EventModifiers) -> KeyboardShortcut? {
    let keys = Array("1234567890")
    guard keys.indices.contains(index) else { return nil }
    return KeyboardShortcut(KeyEquivalent(keys[index]), modifiers: modifiers)
  }

  private func label(for session: Session) -> String {
    let name = session.name
    switch session.status {
    case .needsInput:
      return "● \(name)"
    case .working:
      return "\(name) — working"
    case .idle, .ended:
      return "\(name) — idle"
    }
  }

  /// The session's title, and while it needs input, the agent's message.
  private func subtitle(for session: Session) -> String? {
    let message = session.status == .needsInput ? session.message : nil
    let parts = [session.title, message].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " — ")
  }
}

/// The menu bar icon, badged while any session needs input. With `showsCount`, the number of such
/// sessions is shown next to the plain icon instead of the badge. `isPreviewingCount` shows a
/// sample count of 1 when nothing is waiting.
private struct MenuBarLabel: View {
  let count: Int
  let showsCount: Bool
  let isPreviewingCount: Bool

  var body: some View {
    let shownCount = count > 0 || !isPreviewingCount ? count : 1
    if showsCount && shownCount > 0 {
      HStack {
        Image("MenuBarIcon")
        Text("\(shownCount)")
          .monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    } else {
      Image(count > 0 ? "MenuBarIconAttention" : "MenuBarIcon")
        .accessibilityLabel(accessibilityLabel)
    }
  }

  private var accessibilityLabel: String {
    count > 0 ? "Waiting: \(count) need input" : "Waiting"
  }
}

/// Opens the Settings window. The app has no Dock icon, so it must activate itself first or the
/// window opens behind the frontmost app.
private struct SettingsButton: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Settings…") {
      NSApp.activate()
      openSettings()
      // When Settings is already open behind other apps' windows, activating doesn't always raise
      // it, so raise it explicitly once SwiftUI has shown it.
      Task { @MainActor in
        let window = NSApp.windows.first {
          $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
      }
    }
    .keyboardShortcut(",")
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Opening the app while it's running (from Finder or Spotlight, say) would have SwiftUI reopen
  /// its first window scene, which is onboarding, even after it's been completed. Open the menu
  /// instead: there's no main window, and whoever opened the app may be looking for the icon.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // Opens it later (in a task), which matters: the menu tracks the mouse until it closes, and
    // the reopen event's sender waits for a reply.
    MenuBarList.open()
    return false
  }
}
