import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("waiting: \(message)\n".utf8))
  exit(1)
}

let usage = """
  usage: waiting setup claude                  install Claude Code hooks
         waiting setup codex                   install Codex hooks
         waiting setup vscode                  install the VS Code extension for terminal focus
         waiting hook claude < hook-input.json  handle a Claude Code hook event
         waiting hook codex < hook-input.json   handle a Codex hook event
  """

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "hook":
  runHook(arguments.dropFirst())
case "setup":
  runSetup(arguments.dropFirst())
default:
  fail(usage)
}
