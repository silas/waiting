import AppKit
import SwiftUI

/// The guide shown on first launch: agent setup, alert preferences, then general settings. It's a
/// `Window` scene (`OnboardingWindow`) that SwiftUI presents at launch, and it's shown only once
/// (`onboarding.completed` in UserDefaults).
enum Onboarding {
  static let windowID = "onboarding"
  private static let completedKey = "onboarding.completed"

  static var isCompleted: Bool {
    get { UserDefaults.standard.bool(forKey: completedKey) }
    set { UserDefaults.standard.set(newValue, forKey: completedKey) }
  }
}

struct OnboardingWindow: Scene {
  let launchAtLogin: LaunchAtLogin
  let agents: [AgentHooksStatus]
  let vscode: VSCodeExtensionStatus
  let attention: AttentionSettings
  let shortcuts: ShortcutSettings
  let updater: Updater

  var body: some Scene {
    Window("Welcome to Waiting", id: Onboarding.windowID) {
      OnboardingView(
        launchAtLogin: launchAtLogin, agents: agents, vscode: vscode, attention: attention,
        shortcuts: shortcuts,
        updater: updater
      )
      .windowMinimizeBehavior(.disabled)
      .windowFullScreenBehavior(.disabled)
      .background(OnlyCloseButton())
    }
    .windowResizability(.contentSize)
    // Floats above other apps' windows, so it isn't lost when the user clicks elsewhere.
    .windowLevel(.floating)
    // SwiftUI opens it at launch. Read once, at launch: after onboarding it stays closed.
    .defaultLaunchBehavior(Onboarding.isCompleted ? .suppressed : .presented)
    .restorationBehavior(.disabled)
  }
}

private struct OnboardingView: View {
  let launchAtLogin: LaunchAtLogin
  let agents: [AgentHooksStatus]
  let vscode: VSCodeExtensionStatus
  let attention: AttentionSettings
  let shortcuts: ShortcutSettings
  let updater: Updater

  @Environment(\.dismissWindow) private var dismissWindow

  @State private var step = Step.agents

  enum Step: Int, CaseIterable {
    case agents, alerts, general

    var previous: Step? { Step(rawValue: rawValue - 1) }
    var next: Step? { Step(rawValue: rawValue + 1) }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 24)
        .padding(.top, 20)
      Form {
        switch step {
        case .agents:
          AgentsSection(agents: agents)
          if !vscode.entries.isEmpty {
            EditorsSection(status: vscode)
          }
          Section {
            Label {
              Text(
                "macOS will ask whether Waiting can control your terminal, once for each terminal app. Allow it so Waiting can tell which tab you're in and switch to a session's tab."
              )
            } icon: {
              Image(systemName: "lock.shield")
            }
            .foregroundStyle(.secondary)
          } header: {
            Text("Permissions")
          }
        case .alerts:
          AttentionSection(settings: attention)
        case .general:
          StartupSection(launchAtLogin: launchAtLogin)
          ShortcutsSection(shortcuts: shortcuts)
          UpdatesSection(updater: updater)
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
      footer
        .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 480)
    .onAppear {
      // Shown once: marked when it appears, not when it closes, since quitting the app also
      // closes it (and runs onDisappear).
      Onboarding.isCompleted = true
      // The app has no Dock icon, so it isn't active, and the window would open behind other apps.
      NSApp.activate()
    }
    .onDisappear {
      AppleScriptRunner.isPaused = false
    }
    .task {
      async let agents: Void = agents.refresh()
      async let vscode: Void = vscode.refresh()
      _ = await (agents, vscode)
    }
  }

  private var header: some View {
    VStack(spacing: 6) {
      Image(nsImage: .appIcon)
        .resizable()
        .frame(width: 64, height: 64)
      Text(title)
        .font(.title2.bold())
      Text(subtitle)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        // Wraps instead of truncating: the window sizes to its content, which otherwise squeezes
        // this to one line.
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var title: String {
    switch step {
    case .agents: "Connect Your Agents"
    case .alerts: "Choose Your Alerts"
    case .general: "Finishing Up"
    }
  }

  private var subtitle: String {
    switch step {
    case .agents:
      "Waiting lives in the menu bar and shows which agent sessions need your input."
    case .alerts:
      "The menu bar icon changes whenever a session is waiting. Turn on more alerts below."
    case .general:
      "Waiting starts at login, and a global shortcut jumps to sessions that need input. You can change these anytime in Settings."
    }
  }

  private func close() {
    dismissWindow(id: Onboarding.windowID)
  }

  private var footer: some View {
    HStack {
      if step.next != nil {
        Button("Skip", action: close)
      }
      Spacer()
      Text("\(step.rawValue + 1) of \(Step.allCases.count)")
        .foregroundStyle(.secondary)
      Spacer()
      if let previous = step.previous {
        Button("Back") { step = previous }
      }
      if let next = step.next {
        Button("Continue") { step = next }
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Done", action: close)
          .keyboardShortcut(.defaultAction)
      }
    }
    .controlSize(.large)
  }
}

/// Hides the window's minimize and zoom buttons, leaving only close. Disabling them still leaves the
/// zoom button's Move & Resize menu, and SwiftUI has no way to hide them.
private struct OnlyCloseButton: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { WindowButtonsView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class WindowButtonsView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
      window?.standardWindowButton(.zoomButton)?.isHidden = true
    }
  }
}
