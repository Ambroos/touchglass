// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchGlass",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TouchGlass", targets: ["TouchGlass"]),
        .library(name: "TouchGlassCore", targets: ["TouchGlassCore"]),
        .library(name: "TouchGlassPanel", targets: ["TouchGlassPanel"]),
        .library(name: "TouchGlassHost", targets: ["TouchGlassHost"]),
        .executable(name: "touchglass-pinentry", targets: ["touchglass-pinentry"]),
        .library(name: "TouchGlassIPC", targets: ["TouchGlassIPC"]),
        .executable(name: "touchglass-scdaemon", targets: ["touchglass-scdaemon"]),
    ],
    targets: [
        // Panel states, copy, timing and the state machine. Foundation and Observation only.
        .target(name: "TouchGlassCore"),
        // SwiftUI views and the AppKit panel window.
        .target(name: "TouchGlassPanel", dependencies: ["TouchGlassCore"]),
        // The host: merges proxy and pinentry messages into panel events. Foundation only, no UI.
        .target(name: "TouchGlassHost", dependencies: ["TouchGlassCore", "TouchGlassIPC"]),
        // The app: the host with its panel, plus demo and sample modes.
        .executableTarget(name: "TouchGlass", dependencies: ["TouchGlassCore", "TouchGlassPanel", "TouchGlassHost", "TouchGlassIPC"]),
        .testTarget(name: "TouchGlassCoreTests", dependencies: ["TouchGlassCore"]),
        .testTarget(name: "TouchGlassPanelTests", dependencies: ["TouchGlassPanel"]),
        .testTarget(
            name: "TouchGlassHostTests",
            dependencies: ["TouchGlassHost", "TouchGlassCore", "TouchGlassIPC", "ScdTestSupport", "touchglass-scdaemon", "fake-scdaemon", "touchglass-pinentry"]
        ),
        // Messages and newline-delimited JSON transport between the helpers and the host. Foundation and Darwin only.
        .target(name: "TouchGlassIPC"),
        .testTarget(name: "TouchGlassIPCTests", dependencies: ["TouchGlassIPC"]),
        // The pinentry-program: an Assuan pinentry server on stdio that forwards prompts to the host.
        .executableTarget(name: "touchglass-pinentry", dependencies: ["TouchGlassIPC"]),
        .testTarget(name: "PinentryTests", dependencies: ["touchglass-pinentry", "TouchGlassIPC"]),

        // touchglass-scdaemon: the scdaemon proxy and its test tools.
        // Assuan line tap, operation detector, relay and host event sink. Foundation and Darwin only.
        .target(name: "ScdProxyCore", dependencies: ["TouchGlassIPC"]),
        .executableTarget(name: "touchglass-scdaemon", dependencies: ["ScdProxyCore"]),
        // Fake agent driver and fake host shared by the test tools and the tests.
        .target(name: "ScdTestSupport", dependencies: ["ScdProxyCore", "TouchGlassIPC"]),
        .executableTarget(name: "fake-scdaemon"),
        .executableTarget(name: "fake-agent", dependencies: ["ScdTestSupport"]),
        .executableTarget(name: "fake-host", dependencies: ["ScdTestSupport"]),
        .testTarget(
            name: "ScdProxyTests",
            dependencies: ["ScdProxyCore", "ScdTestSupport", "TouchGlassIPC", "touchglass-scdaemon", "fake-scdaemon", "fake-host"]
        ),
    ]
)
