import SwiftUI

struct SettingsView: View {
  let shortcuts: ShortcutSettings
  let vscode: VSCodeExtensionStatus
  let attention: AttentionSettings
  let updater: Updater

  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        SettingsForm {
          ShortcutsSection(shortcuts: shortcuts)
          UpdatesSection(updater: updater)
        }
      }
      Tab("Alerts", systemImage: "bell") {
        SettingsForm {
          AttentionSection(settings: attention)
        }
      }
      Tab("Integrations", systemImage: "puzzlepiece.extension") {
        SettingsForm {
          VSCodeSection(status: vscode)
        }
      }
    }
    .task {
      await vscode.refresh()
    }
  }
}

/// A settings tab's content: a grouped form sized to fit. The form never needs to scroll, and
/// hiding the scroller stops it flashing while the window resizes between tabs.
private struct SettingsForm<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Form {
      content
    }
    .formStyle(.grouped)
    .scrollIndicators(.never)
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct ShortcutsSection: View {
  let shortcuts: ShortcutSettings

  var body: some View {
    Section("Global Shortcuts") {
      ForEach(ShortcutAction.allCases) { action in
        LabeledContent(action.title) {
          ShortcutRecorder(action: action, settings: shortcuts)
        }
        if shortcuts.unavailable.contains(action) {
          Text("This shortcut is in use by another app.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      Button("Restore Defaults") {
        shortcuts.restoreDefaults()
      }
    }
  }
}

private struct AttentionSection: View {
  @Bindable var settings: AttentionSettings

  var body: some View {
    Section {
      Toggle("Show count in menu bar", isOn: $settings.showsCount)
      Toggle("Pulse menu bar icon", isOn: $settings.pulsesIcon)
      Toggle("Glow top edge of screen", isOn: $settings.glowsScreenEdge)
      if settings.glowsScreenEdge {
        Picker("Glow color", selection: $settings.glowColor) {
          ForEach(AttentionSettings.GlowColor.allCases) { color in
            Text(color.title).tag(color)
          }
        }
        if settings.glowColor == .custom {
          ColorPicker("Custom color", selection: $settings.customGlowColor, supportsOpacity: false)
        }
      }
    } header: {
      Text("When a Session Needs Input")
    } footer: {
      Text("The pulse and glow play once, when a session starts waiting.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    // Demo the count and pulse when they're turned on, and the glow when it's turned on or recolored.
    .onChange(of: settings.showsCount) { _, isOn in
      if isOn { settings.previewCount() }
    }
    .onChange(of: settings.pulsesIcon) { _, isOn in
      if isOn { MenuBarList.pulse() }
    }
    .onChange(of: settings.glowsScreenEdge) { _, isOn in
      if isOn { ScreenEdgeGlow.flash(color: settings.resolvedGlowColor) }
    }
    .onChange(of: settings.glowColor) {
      ScreenEdgeGlow.flash(color: settings.resolvedGlowColor)
    }
    .onChange(of: settings.customGlowColor) {
      ScreenEdgeGlow.flash(color: settings.resolvedGlowColor)
    }
  }
}

private struct UpdatesSection: View {
  @Bindable var updater: Updater

  var body: some View {
    Section("Updates") {
      Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
      LabeledContent("Version \(version)") {
        Button("Check Now") {
          updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
      }
    }
  }

  private var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let short = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}

/// Installs the extension that lets Waiting select the terminal a session is in.
private struct VSCodeSection: View {
  let status: VSCodeExtensionStatus

  var body: some View {
    Section {
      if status.entries.isEmpty {
        Text(
          "None of \(VSCodeExtension.editors.map(\.name).formatted(.list(type: .or))) is installed."
        )
        .foregroundStyle(.secondary)
      }
      ForEach(status.entries) { entry in
        LabeledContent(entry.editor.name) {
          HStack {
            Text(state(of: entry))
              .foregroundStyle(.secondary)
            if status.installing.contains(entry.id) {
              ProgressView()
                .controlSize(.small)
            } else if entry.installedVersion == nil {
              button("Install", entry)
            } else if status.isOutdated(entry) {
              button("Update", entry)
            }
          }
        }
        if let error = status.errors[entry.id] {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    } header: {
      Text("VS Code Extension")
    } footer: {
      Text("Lets Waiting select the terminal tab a session is running in.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func state(of entry: VSCodeExtensionStatus.Entry) -> String {
    guard let version = entry.installedVersion else { return "Not installed" }
    if status.needsReload.contains(entry.id) {
      return "Installed — reload open windows"
    }
    return status.isOutdated(entry) ? "Version \(version)" : "Installed"
  }

  private func button(_ title: String, _ entry: VSCodeExtensionStatus.Entry) -> some View {
    Button(title) {
      Task { await status.install(entry.editor) }
    }
  }
}
