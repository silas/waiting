import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let launchAtLogin: LaunchAtLogin
  let shortcuts: ShortcutSettings
  let agents: [AgentHooksStatus]
  let vscode: VSCodeExtensionStatus
  let attention: AttentionSettings
  let updater: Updater

  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        SettingsForm {
          StartupSection(launchAtLogin: launchAtLogin)
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
          AgentsSection(agents: agents)
          if !vscode.entries.isEmpty {
            EditorsSection(status: vscode)
          }
        }
      }
    }
    .task {
      async let agents: Void = agents.refresh()
      async let vscode: Void = vscode.refresh()
      _ = await (agents, vscode)
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

struct StartupSection: View {
  @Bindable var launchAtLogin: LaunchAtLogin

  var body: some View {
    Section {
      Toggle("Start at login", isOn: $launchAtLogin.isEnabled)
      if launchAtLogin.status == .requiresApproval {
        LabeledContent("Allow Waiting in Login Items to finish.") {
          Button("Open Settings") {
            SMAppService.openSystemSettingsLoginItems()
          }
        }
        .font(.caption)
      }
      if let error = launchAtLogin.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .onAppear { launchAtLogin.refresh() }
    // The user can change it in System Settings while this window is open.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      launchAtLogin.refresh()
    }
  }
}

struct ShortcutsSection: View {
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

struct AttentionSection: View {
  @Bindable var settings: AttentionSettings

  var body: some View {
    Section {
      Toggle("Show count in menu bar", isOn: $settings.showsCount)
      Toggle("Pulse menu bar icon", isOn: $settings.pulsesIcon)
      Toggle("Show popup under menu bar icon", isOn: $settings.showsPopup)
      Toggle("Play sound", isOn: $settings.playsSound)
      if settings.playsSound {
        Picker("Sound", selection: $settings.soundName) {
          ForEach(AttentionSettings.soundNames, id: \.self) { name in
            Text(name).tag(name)
          }
        }
      }
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
      Text(
        "Alerts play once when a session starts waiting, unless you're already in its terminal tab."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    // Demo the count, pulse and popup when they're turned on, the sound when it's turned on or changed, and
    // the glow when it's turned on or recolored.
    .onChange(of: settings.showsCount) { _, isOn in
      if isOn { settings.previewCount() }
    }
    .onChange(of: settings.pulsesIcon) { _, isOn in
      if isOn { MenuBarList.pulse() }
    }
    .onChange(of: settings.showsPopup) { _, isOn in
      if isOn { settings.previewPopup() }
    }
    .onChange(of: settings.playsSound) { _, isOn in
      if isOn { settings.playSound() }
    }
    .onChange(of: settings.soundName) {
      settings.playSound()
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

struct UpdatesSection: View {
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

/// Installs the hooks that tell Waiting what each agent's sessions are doing.
struct AgentsSection: View {
  let agents: [AgentHooksStatus]

  var body: some View {
    Section {
      if !agents.allSatisfy(\.isLoaded) {
        // Looking up the config directories can take seconds; don't claim nothing is installed.
        Text("Looking for agents…")
          .foregroundStyle(.secondary)
      } else if agents.contains(where: \.isDetected) {
        ForEach(agents.filter(\.isDetected)) { agent in
          AgentRow(agent: agent)
        }
      } else {
        Text("No agents detected.")
          .foregroundStyle(.secondary)
      }
      ForEach(agents.filter { $0.isLoaded && !$0.isConfigDirectoryKnown }) { agent in
        // Installing into the default directory is right for most people, but if they set the
        // variable, the agent would never run the hooks.
        let hooks = agent.hooks
        Text(
          "Waiting couldn't read \(hooks.configVariable) from your shell profile, so it's using ~/\(hooks.defaultConfigDirectory). If you set \(hooks.configVariable), install the \(hooks.name) hooks from a terminal instead:\n\(hooks.setupCommand)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      }
    } header: {
      Text("Agents")
    } footer: {
      Text(
        "Hooks let Waiting know when a session is working or needs input. Without them, Waiting can't see your sessions."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    // The user may have just trusted the hooks in Codex, or edited the hooks file.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await agents.refresh() }
    }
  }
}

/// One agent's hooks: whether they're installed, and a button to install or update them.
private struct AgentRow: View {
  let agent: AgentHooksStatus

  var body: some View {
    LabeledContent(agent.hooks.name) {
      HStack {
        Text(state)
          .foregroundStyle(.secondary)
        if agent.isInstalling {
          ProgressView()
            .controlSize(.small)
        } else if agent.isTemporaryLocation {
          // No button: the hooks would point at a path that goes away. The note below says what
          // to do.
          EmptyView()
        } else if agent.status == .notInstalled {
          button("Install")
        } else if agent.status == .outdated {
          button("Update")
        }
      }
    }
    if agent.isTemporaryLocation, agent.status == .notInstalled || agent.status == .outdated {
      Text(
        "Waiting is running from a disk image or a temporary location. Move it to Applications and open it from there to install hooks."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    if agent.status == .untrusted {
      Text(
        "\(agent.hooks.name) only runs hooks you trust. Type /hooks in \(agent.hooks.name) and trust the Waiting hooks."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    if let error = agent.error {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private var state: String {
    switch agent.status {
    case .notInstalled: "Not installed"
    case .outdated: "Outdated"
    case .untrusted: "Not trusted"
    case .installed: agent.needsRestart ? "Installed — restart running sessions" : "Installed"
    }
  }

  private func button(_ title: String) -> some View {
    Button(title) {
      Task { await agent.install() }
    }
  }
}

/// Installs the extension that lets Waiting tell which terminal is focused and select a session's,
/// in each installed VS Code-family editor.
struct EditorsSection: View {
  let status: VSCodeExtensionStatus

  var body: some View {
    Section {
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
      Text("Editors")
    } footer: {
      Text(
        "If you run agents in an editor's terminal, install the extension so Waiting can tell which terminal you're in and switch to a session's."
      )
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
