import AppKit
import SwiftUI

/// A small banner that drops down under the menu bar icon, like the one macOS shows when
/// headphones connect. It names the session and fades out on its own after a few seconds, but stays
/// while the pointer is over it. Clicking it runs `action` (showing the session) and dismisses it.
/// Showing it again while it's up replaces its content and restarts the hold. It shows the agent's
/// logo for agents that have one (`PopupView.agentIcons`), and the app icon otherwise.
enum MenuBarPopup {
  /// The popup is as wide as its text, up to this.
  private static let maxWidth: CGFloat = 280
  /// The space between the bottom of the menu bar and the top of the popup.
  private static let gap: CGFloat = 6
  private static let holdDuration: Duration = .seconds(4)
  private static var window: NSPanel?
  /// Bumped on every show and dismiss, so only the latest one fades the popup out.
  private static var generation = 0

  static func show(
    title: String, subtitle: String, agent: String? = nil, action: (() -> Void)? = nil
  ) {
    let window = window ?? makeWindow()
    self.window = window
    let content = PopupView(title: title, subtitle: subtitle, agent: agent) {
      dismiss()
      action?()
    }
    let hostingView = FirstMouseHostingView(rootView: content.frame(maxWidth: maxWidth))
    window.contentView = hostingView
    window.setFrame(frame(for: hostingView.fittingSize), display: false)
    if !window.isVisible {
      window.alphaValue = 0
      window.orderFrontRegardless()
    }

    generation += 1
    let current = generation
    Task {
      fade(window, to: 1, duration: 0.2)
      try? await Task.sleep(for: holdDuration)
      while generation == current, NSMouseInRect(NSEvent.mouseLocation, window.frame, false) {
        try? await Task.sleep(for: .milliseconds(500))
      }
      guard generation == current else { return }
      fadeOut(window, generation: current)
    }
  }

  private static func dismiss() {
    guard let window else { return }
    generation += 1
    fadeOut(window, generation: generation)
  }

  private static func fadeOut(_ window: NSWindow, generation current: Int) {
    Task {
      fade(window, to: 0, duration: 0.4)
      try? await Task.sleep(for: .seconds(0.4))
      guard generation == current else { return }
      window.orderOut(nil)
    }
  }

  /// Centered under the menu bar icon and kept on its screen. When the icon can't be found (hidden
  /// behind the notch, say), it goes at the right end of the menu bar of the screen the pointer is
  /// on, where status items live.
  private static func frame(for size: NSSize) -> NSRect {
    if let icon = MenuBarList.statusButtonFrame(),
      let screen = NSScreen.screens.first(where: { NSIntersectsRect(icon, $0.frame) })
    {
      let x = min(
        max(icon.midX - size.width / 2, screen.frame.minX + gap),
        screen.frame.maxX - size.width - gap)
      return NSRect(x: x, y: icon.minY - gap - size.height, width: size.width, height: size.height)
    }
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    let frame = screen?.frame ?? .zero
    let menuBarBottom = screen?.visibleFrame.maxY ?? frame.maxY
    return NSRect(
      x: frame.maxX - size.width - gap * 2,
      y: menuBarBottom - gap - size.height,
      width: size.width,
      height: size.height)
  }

  private static func makeWindow() -> NSPanel {
    let window = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.becomesKeyOnlyIfNeeded = true
    // Above other windows, and on every Space including full-screen ones.
    window.level = .statusBar
    window.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    return window
  }

  private static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      window.animator().alphaValue = alpha
    }
  }
}

/// Takes the click that brings the panel forward, so one click on the popup runs its action.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSImage {
  /// The app icon, loaded from the bundle: `NSApp.applicationIconImage` goes through the system's
  /// icon cache, which can still have the generic icon for the build (as it does for Debug builds).
  static let appIcon = Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage!
}

private struct PopupView: View {
  /// Asset catalog images by `Session.agent`. Template images (Codex) take the text color.
  private static let agentIcons = ["claude": "ClaudeIcon", "codex": "CodexIcon"]

  let title: String
  let subtitle: String
  let agent: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        icon
          .frame(width: 36, height: 36)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.headline)
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
      }
      .padding(.vertical, 8)
      .padding(.leading, 8)
      .padding(.trailing, 20)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular, in: .capsule)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var icon: some View {
    if let name = agent.flatMap({ Self.agentIcons[$0] }) {
      // The logo has no background of its own, so it's inset to match the app icon's visual size.
      Image(name)
        .resizable()
        .scaledToFit()
        .padding(4)
    } else {
      Image(nsImage: .appIcon)
        .resizable()
    }
  }
}
