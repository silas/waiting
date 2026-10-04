import AppKit
import Observation
import SwiftUI

/// Optional extra ways of signaling that a session needs input, on top of the menu bar icon's
/// badge. All are off by default and persisted to UserDefaults (`attention.<name>`).
@Observable final class AttentionSettings {
  /// Shows the number of sessions needing input next to the menu bar icon, in place of the badge.
  var showsCount: Bool {
    didSet { UserDefaults.standard.set(showsCount, forKey: Keys.showsCount) }
  }

  /// Pulses the menu bar icon when a session starts needing input.
  var pulsesIcon: Bool {
    didSet { UserDefaults.standard.set(pulsesIcon, forKey: Keys.pulsesIcon) }
  }

  /// Briefly glows the top edge of the screen when a session starts needing input.
  var glowsScreenEdge: Bool {
    didSet { UserDefaults.standard.set(glowsScreenEdge, forKey: Keys.glowsScreenEdge) }
  }

  var glowColor: GlowColor {
    didSet { UserDefaults.standard.set(glowColor.rawValue, forKey: Keys.glowColor) }
  }

  /// The color used when `glowColor` is `.custom`, stored as sRGB components.
  var customGlowColor: Color {
    didSet {
      guard let srgb = NSColor(customGlowColor).usingColorSpace(.sRGB) else { return }
      let components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
      UserDefaults.standard.set(components.map(Double.init), forKey: Keys.customGlowColor)
    }
  }

  enum GlowColor: String, CaseIterable, Identifiable {
    case accent, amber, purple, custom

    var id: String { rawValue }

    var title: String {
      switch self {
      case .accent: "System Accent"
      case .amber: "Amber"
      case .purple: "Purple"
      case .custom: "Custom"
      }
    }
  }

  private static let amber = Color(red: 1, green: 0.75, blue: 0.1)

  private enum Keys {
    static let showsCount = "attention.showsCount"
    static let pulsesIcon = "attention.pulsesIcon"
    static let glowsScreenEdge = "attention.glowsScreenEdge"
    static let glowColor = "attention.glowColor"
    static let customGlowColor = "attention.customGlowColor"
  }

  init() {
    let defaults = UserDefaults.standard
    showsCount = defaults.bool(forKey: Keys.showsCount)
    pulsesIcon = defaults.bool(forKey: Keys.pulsesIcon)
    glowsScreenEdge = defaults.bool(forKey: Keys.glowsScreenEdge)
    glowColor = defaults.string(forKey: Keys.glowColor).flatMap(GlowColor.init) ?? .accent
    if let rgb = defaults.array(forKey: Keys.customGlowColor) as? [Double], rgb.count == 3 {
      customGlowColor = Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    } else {
      customGlowColor = Self.amber
    }
  }

  /// The color the glow is drawn in. A graphite accent would make a gray glow that's easy to
  /// miss, so the accent option falls back to amber then.
  var resolvedGlowColor: Color {
    switch glowColor {
    case .accent:
      let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
      return (accent?.saturationComponent ?? 0) < 0.1
        ? Self.amber : Color(nsColor: .controlAccentColor)
    case .amber: return Self.amber
    case .purple: return Color(nsColor: .systemPurple)
    case .custom: return customGlowColor
    }
  }

  /// Whether the menu bar is showing a sample count, so turning the count on shows what it looks
  /// like even when nothing is waiting.
  private(set) var isPreviewingCount = false

  /// Bumped on every count preview, so only the latest one ends it.
  @ObservationIgnored private var countPreviewGeneration = 0

  /// Shows a sample count in the menu bar for a couple of seconds.
  func previewCount() {
    countPreviewGeneration += 1
    let current = countPreviewGeneration
    isPreviewingCount = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      if countPreviewGeneration == current {
        isPreviewingCount = false
      }
    }
  }

  /// Plays the enabled one-shot effects. Called when a session starts needing input.
  func announce() {
    if pulsesIcon {
      MenuBarList.pulse()
    }
    if glowsScreenEdge {
      ScreenEdgeGlow.flash(color: resolvedGlowColor)
    }
  }
}
