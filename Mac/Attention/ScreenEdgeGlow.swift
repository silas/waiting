import AppKit
import SwiftUI

/// A glow along the top edge of the screen the pointer is on, which fades in and out on its own.
/// It ignores the mouse and never takes focus. Flashing again while it's showing recolors it and
/// restarts the hold instead of fading in from nothing, so rapid calls (dragging in a color picker)
/// give a live preview.
enum ScreenEdgeGlow {
  private static let height: CGFloat = 56
  private static var window: NSPanel?
  /// Bumped on every flash, so only the latest one fades the glow out.
  private static var generation = 0

  static func flash(color: Color) {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        ?? NSScreen.main
    else { return }

    let window = window ?? makeWindow()
    self.window = window
    window.setFrame(
      NSRect(
        x: screen.frame.minX,
        y: screen.frame.maxY - height,
        width: screen.frame.width,
        height: height
      ), display: false)
    window.contentView = NSHostingView(
      rootView: LinearGradient(
        colors: [color.opacity(0.75), color.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
      ))
    if !window.isVisible {
      window.alphaValue = 0
      window.orderFrontRegardless()
    }

    generation += 1
    let current = generation
    Task {
      fade(window, to: 1, duration: 0.25)
      try? await Task.sleep(for: .seconds(1.25))
      guard generation == current else { return }
      fade(window, to: 0, duration: 1)
      try? await Task.sleep(for: .seconds(1))
      guard generation == current else { return }
      window.orderOut(nil)
    }
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
    window.hasShadow = false
    window.ignoresMouseEvents = true
    // Above the menu bar, and on every Space including full-screen ones.
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
