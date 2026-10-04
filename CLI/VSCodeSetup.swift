import Foundation

/// Installs the Waiting extension (`waiting.vsix` in the app's Resources) into every installed
/// VS Code-family editor.
func setupVSCode() {
  guard VSCodeExtension.bundledVSIX != nil else {
    fail("waiting.vsix not found; run the copy of waiting inside Waiting.app")
  }
  let editors = VSCodeExtension.editors.filter { $0.cliURL != nil }
  guard !editors.isEmpty else {
    fail("no VS Code-family editor found")
  }

  var installed: [String] = []
  for editor in editors {
    do {
      try VSCodeExtension.install(in: editor)
      installed.append(editor.name)
    } catch {
      print(error.localizedDescription)
    }
  }

  guard !installed.isEmpty else { exit(1) }
  print("Installed the Waiting extension into \(installed.joined(separator: ", ")).")
  print("Reload open windows (Developer: Reload Window) to activate it.")
}
