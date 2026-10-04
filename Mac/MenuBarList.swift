import AppKit

enum MenuBarList {
  /// SwiftUI has no API to open a `MenuBarExtra`, so click its status item button. Waits (up to
  /// 2s) for ⌥ to be released first, since the menu shows its alternate "Remove" items while it's
  /// held, as when the shortcut that opened it includes ⌥.
  static func open() {
    Task { @MainActor in
      let deadline = ContinuousClock.now + .seconds(2)
      while NSEvent.modifierFlags.contains(.option), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      statusButton()?.performClick(nil)
    }
  }

  /// Blinks the status item a few times. SwiftUI doesn't animate `MenuBarExtra` labels, so this
  /// animates the button's layer directly; the model opacity never changes.
  static func pulse() {
    guard let button = statusButton() else { return }
    button.wantsLayer = true
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = [1, 0.15, 1, 0.15, 1, 0.15, 1]
    animation.duration = 1.8
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    button.layer?.add(animation, forKey: "pulse")
  }

  /// The status item's frame in screen coordinates, or nil if it isn't on screen.
  static func statusButtonFrame() -> NSRect? {
    guard let button = statusButton(), let window = button.window, window.isVisible else {
      return nil
    }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  private static func statusButton() -> NSStatusBarButton? {
    NSApp.windows
      .filter { $0.className.contains("NSStatusBarWindow") }
      .compactMap { window in window.contentView.flatMap { findButton(in: $0) } }
      .first
  }

  private static func findButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    return view.subviews.lazy.compactMap { findButton(in: $0) }.first
  }
}
