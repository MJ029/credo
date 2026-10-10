// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Credo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Credo", targets: ["Credo"])
    ],
    targets: [
        // Foundation-only log parsing, pricing and aggregation.
        .target(name: "TokenCore"),
        // SwiftUI menu bar app + desktop widget.
        .executableTarget(name: "Credo", dependencies: ["TokenCore"])
    ]
)
