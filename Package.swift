// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TabManager",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TabCore"),
        .executableTarget(name: "TabManager", dependencies: ["TabCore"]),
        .executableTarget(name: "tabcheck", dependencies: ["TabCore"]),
    ],
    swiftLanguageModes: [.v5]
)
