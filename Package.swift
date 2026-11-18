// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchGlass",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TouchGlass", targets: ["TouchGlass"]),
        .library(name: "TouchGlassCore", targets: ["TouchGlassCore"]),
        .library(name: "TouchGlassPanel", targets: ["TouchGlassPanel"]),
        .executable(name: "touchglass-pinentry", targets: ["touchglass-pinentry"]),
        .library(name: "TouchGlassIPC", targets: ["TouchGlassIPC"]),
    ],
    targets: [
        // Panel states, copy, timing and the state machine. Foundation and Observation only.
        .target(name: "TouchGlassCore"),
        // SwiftUI views and the AppKit panel window.
        .target(name: "TouchGlassPanel", dependencies: ["TouchGlassCore"]),
        // The app: argument parsing and demo mode.
        .executableTarget(name: "TouchGlass", dependencies: ["TouchGlassCore", "TouchGlassPanel"]),
        .testTarget(name: "TouchGlassCoreTests", dependencies: ["TouchGlassCore"]),
        // Messages and newline-delimited JSON transport between the helpers and the host. Foundation and Darwin only.
        .target(name: "TouchGlassIPC"),
        .testTarget(name: "TouchGlassIPCTests", dependencies: ["TouchGlassIPC"]),
        // The pinentry-program: an Assuan pinentry server on stdio that forwards prompts to the host.
        .executableTarget(name: "touchglass-pinentry", dependencies: ["TouchGlassIPC"]),
        .testTarget(name: "PinentryTests", dependencies: ["touchglass-pinentry", "TouchGlassIPC"]),
    ]
)
