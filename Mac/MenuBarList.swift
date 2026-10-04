import AppKit

enum MenuBarList {
  /// SwiftUI has no API to open a `MenuBarExtra`, so click its status item button.
  static func open() {
    statusButton()?.performClick(nil)
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
