import Foundation
import Observation

/// Whether each installed VS Code-family editor has the Waiting extension, for Settings. Also keeps
/// copies that are already installed up to date with the one bundled in the app.
@Observable final class VSCodeExtensionStatus {
  nonisolated struct Entry: Identifiable, Sendable {
    let editor: VSCodeExtension.Editor
    let installedVersion: String?

    var id: String { editor.id }
  }

  private(set) var bundledVersion: String?
  /// One per installed editor.
  private(set) var entries: [Entry] = []
  private(set) var installing: Set<String> = []
  /// Last install error per editor ID.
  private(set) var errors: [String: String] = [:]
  /// Editors that got a new copy since launch. Their open windows run the old one until reloaded.
  private(set) var needsReload: Set<String> = []

  func isOutdated(_ entry: Entry) -> Bool {
    guard let installed = entry.installedVersion, let bundledVersion else { return false }
    return VSCodeExtension.isOutdated(installed, comparedTo: bundledVersion)
  }

  func refresh() async {
    (bundledVersion, entries) = await Self.load()
  }

  func install(_ editor: VSCodeExtension.Editor) async {
    installing.insert(editor.id)
    errors[editor.id] = nil
    do {
      try await Self.install(editor)
      needsReload.insert(editor.id)
    } catch {
      errors[editor.id] = error.localizedDescription
    }
    installing.remove(editor.id)
    await refresh()
  }

  /// Updates the extension in editors that have an older version. Editors without it are left
  /// alone, since installing it is the user's choice.
  func updateInstalled() async {
    await refresh()
    for entry in entries where isOutdated(entry) {
      await install(entry.editor)
    }
  }

  @concurrent private static func load() async -> (String?, [Entry]) {
    let entries = VSCodeExtension.editors.filter { $0.cliURL != nil }.map {
      Entry(editor: $0, installedVersion: VSCodeExtension.installedVersion(in: $0))
    }
    return (VSCodeExtension.bundledVersion(), entries)
  }

  @concurrent private static func install(_ editor: VSCodeExtension.Editor) async throws {
    try VSCodeExtension.install(in: editor)
  }
}
