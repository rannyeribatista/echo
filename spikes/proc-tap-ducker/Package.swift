// swift-tools-version: 5.9
// Spike: universal per-app audio ducking via Core Audio process taps.
// NOT part of the Echo app targets — feasibility CLI only.
import PackageDescription

let package = Package(
    name: "duckctl",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "duckctl", path: "Sources/duckctl")
    ]
)
