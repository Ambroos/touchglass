// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchGlass",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TouchGlass", targets: ["TouchGlass"]),
        .library(name: "TouchGlassCore", targets: ["TouchGlassCore"]),
        .library(name: "TouchGlassPanel", targets: ["TouchGlassPanel"]),
    ],
    targets: [
        // Panel states, copy, timing and the state machine. Foundation and Observation only.
        .target(name: "TouchGlassCore"),
        // SwiftUI views and the AppKit panel window.
        .target(name: "TouchGlassPanel", dependencies: ["TouchGlassCore"]),
        // The app: argument parsing and demo mode.
        .executableTarget(name: "TouchGlass", dependencies: ["TouchGlassCore", "TouchGlassPanel"]),
        .testTarget(name: "TouchGlassCoreTests", dependencies: ["TouchGlassCore"]),
    ]
)
