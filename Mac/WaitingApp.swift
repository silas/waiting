import SwiftUI

@main struct WaitingApp: App {
  @State private var store: SessionStore
  @State private var shortcuts: ShortcutSettings
  @State private var vscode: VSCodeExtensionStatus
  @State private var attention: AttentionSettings
  @State private var updater = Updater()

  init() {
    let store = SessionStore()
    _store = State(initialValue: store)
    let attention = AttentionSettings()
    _attention = State(initialValue: attention)
    store.onStartWaiting = { attention.announce() }
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
  }

  var body: some Scene {
    MenuBarExtra {
      ForEach(Array(store.sorted.enumerated()), id: \.element.id) { index, session in
        Button(title(for: session)) {
          store.show(session)
        }
        .keyboardShortcut(shortcut(forItem: index, modifiers: .command))
        .modifierKeyAlternate(.option) {
          Button("Remove \(name(of: session))") {
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

    Settings {
      SettingsView(shortcuts: shortcuts, vscode: vscode, attention: attention, updater: updater)
    }
  }

  /// 1 through 9, then 0, for the first ten sessions in the menu.
  private func shortcut(forItem index: Int, modifiers: EventModifiers) -> KeyboardShortcut? {
    let keys = Array("1234567890")
    guard keys.indices.contains(index) else { return nil }
    return KeyboardShortcut(KeyEquivalent(keys[index]), modifiers: modifiers)
  }

  private func name(of session: Session) -> String {
    session.cwd.map { URL(filePath: $0).lastPathComponent } ?? session.id
  }

  private func title(for session: Session) -> String {
    let name = name(of: session)
    switch session.status {
    case .needsInput:
      return "● \(name)" + (session.message.map { " — \($0)" } ?? "")
    case .working:
      return "\(name) — working"
    case .idle, .ended:
      return "\(name) — idle"
    }
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
    }
    .keyboardShortcut(",")
  }
}
