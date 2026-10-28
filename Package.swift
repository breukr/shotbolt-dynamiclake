// swift-tools-version: 6.2
import PackageDescription

// The DynamicLake plugin: a small process DynamicLake starts, which shows Shotbolt's recordings and newest captures in the
// notch. It reads Shotbolt's status feed and acts through `shotbolt://` commands. It builds with no Shotbolt code.
let package = Package(
    name: "ShotboltLake",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "shotbolt-lake", targets: ["ShotboltLake"])],
    targets: [
        // Everything that can be tested without DynamicLake or Shotbolt running: the feed, the surfaces, the plugin loop.
        .target(name: "ShotboltLakeCore", path: "Sources/ShotboltLakeCore"),
        .executableTarget(name: "ShotboltLake", dependencies: ["ShotboltLakeCore"], path: "Sources/ShotboltLake"),
        // `Tests/Fixtures/status-v1.json` is a sample of the feed: the format the plugin reads.
        .testTarget(name: "ShotboltLakeTests", dependencies: ["ShotboltLakeCore"], path: "Tests/ShotboltLakeTests"),
    ],
    swiftLanguageModes: [.v5]
)
