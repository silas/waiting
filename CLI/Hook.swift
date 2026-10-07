import Foundation

/// `waiting hook <agent>`: reads the harness's hook input from stdin and posts it to the app.
func runHook(_ arguments: ArraySlice<String>) {
  let input = { FileHandle.standardInput.readDataToEndOfFile() }

  let event: AgentEvent?
  switch arguments.first {
  case "claude":
    event = claudeEvent(from: input())
  case "codex":
    event = codexEvent(from: input())
  default:
    fail(usage)
  }

  // Events that don't map to a session state are dropped.
  guard let event else { return }

  // The payload travels as the `object` string because userInfo is dropped for sandboxed receivers.
  guard let data = try? JSONEncoder().encode(event) else { fail("could not encode event") }
  // The e2e tests post under their own name, so a running copy of the app doesn't see them.
  let name = ProcessInfo.processInfo.environment["WAITING_NOTIFICATION_NAME"].flatMap {
    $0.isEmpty ? nil : Notification.Name($0)
  }
  DistributedNotificationCenter.default().postNotificationName(
    name ?? AgentEvent.notificationName,
    object: String(decoding: data, as: UTF8.self),
    userInfo: nil,
    deliverImmediately: true
  )
}
