// swift-tools-version: 6.0
import PackageDescription

// End-to-end tests for the built Waiting.app and its `waiting` CLI. Run with `make e2e` (see
// CLAUDE.md). Not part of the Xcode project: it tests the build's products from the outside.
let package = Package(
  name: "WaitingE2E",
  platforms: [.macOS(.v15)],
  targets: [
    // Prints the distributed notifications posted under a name, so tests can read the CLI's events.
    .executableTarget(name: "Listener"),
    .testTarget(name: "WaitingE2E", dependencies: ["Listener"]),
  ],
  swiftLanguageModes: [.v5]
)
