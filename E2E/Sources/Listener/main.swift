import Foundation

// `Listener <notification name>`: prints "ready" once it's observing, then each notification's
// `object` (an `AgentEvent` as JSON, one line) as it arrives. Runs until killed.
guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: Listener <notification name>\n".utf8))
  exit(2)
}
setvbuf(stdout, nil, _IOLBF, 0)
let observer = DistributedNotificationCenter.default().addObserver(
  forName: Notification.Name(CommandLine.arguments[1]), object: nil, queue: .main
) { notification in
  guard let object = notification.object as? String else { return }
  print(object.replacingOccurrences(of: "\n", with: " "))
}
print("ready")
RunLoop.main.run()
