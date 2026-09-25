// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FordLink",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FordLinkCore", targets: ["FordLinkCore"]),
        .executable(name: "fordlink", targets: ["fordlink"]),
        .executable(name: "FordLinkApp", targets: ["FordLinkApp"]),
    ],
    targets: [
        .target(name: "FordLinkCore"),
        .executableTarget(name: "fordlink", dependencies: ["FordLinkCore"]),
        // SwiftUI app. Compiles to a stub on non-macOS platforms.
        .executableTarget(name: "FordLinkApp", dependencies: ["FordLinkCore"]),
        .testTarget(name: "FordLinkCoreTests", dependencies: ["FordLinkCore"]),
    ]
)
