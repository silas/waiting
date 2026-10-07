// swift-tools-version: 6.2
import PackageDescription

// Unit tests for logic that the e2e tests (E2E/) can't easily stage from outside, such as process
// tables and config files. Run with `make test` (see CLAUDE.md). `Sources/WaitingCore` holds
// symlinks to the app's sources, compiled with the Xcode project's concurrency settings; link
// another file there to test it.
let package = Package(
  name: "WaitingUnitTests",
  platforms: [.macOS(.v26)],
  targets: [
    .target(
      name: "WaitingCore",
      swiftSettings: [
        // The Xcode project's `SWIFT_DEFAULT_ACTOR_ISOLATION` and approachable concurrency.
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("InferSendableFromCaptures"),
        .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
        .enableUpcomingFeature("DisableOutwardActorInference"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ]
    ),
    .testTarget(name: "WaitingTests", dependencies: ["WaitingCore"]),
  ],
  swiftLanguageModes: [.v5]
)
