import Foundation
import Testing
@testable import TouchGlassIPC

@Suite struct HostLauncherTests {
    @Test func helperInsideTheAppBundleOpensThatBundle() {
        let helper = "/Applications/Tools/TouchGlass.app/Contents/MacOS/touchglass-pinentry"
        #expect(HostLauncher.bundlePath(containing: helper) == "/Applications/Tools/TouchGlass.app")
        #expect(HostLauncher.defaultTarget(executablePath: helper) == "/Applications/Tools/TouchGlass.app")
    }

    @Test func helperOutsideABundleOpensTheAppByName() {
        for path in ["/opt/build/debug/touchglass-scdaemon", "/x/Contents/MacOS/helper", "/x/TouchGlass.app/Contents/Resources/helper"] {
            #expect(HostLauncher.bundlePath(containing: path) == nil)
        }
        #expect(HostLauncher.defaultTarget(executablePath: "/opt/build/debug/touchglass-scdaemon") == "TouchGlass")
        #expect(HostLauncher.defaultTarget(executablePath: nil) == "TouchGlass")
    }

    /// Homebrew's layout: `opt/touchglass` links to the versioned keg, which `brew upgrade` deletes.
    @Test func helperStartedThroughALinkedBundleOpensTheLinkedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostlauncher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keg = root.appendingPathComponent("Cellar/touchglass/1.0")
        let macOS = keg.appendingPathComponent("TouchGlass.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let helper = macOS.appendingPathComponent("touchglass-pinentry")
        try Data().write(to: helper)
        let opt = root.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: opt.appendingPathComponent("touchglass").path, withDestinationPath: "../Cellar/touchglass/1.0")

        let throughOpt = opt.appendingPathComponent("touchglass/TouchGlass.app/Contents/MacOS/touchglass-pinentry").path
        #expect(HostLauncher.defaultTarget(executablePath: throughOpt) == opt.appendingPathComponent("touchglass/TouchGlass.app").path)

        // A link to the helper itself is outside any bundle; the resolved path finds the bundle.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let linkedHelper = bin.appendingPathComponent("touchglass-pinentry")
        try FileManager.default.createSymbolicLink(at: linkedHelper, withDestinationURL: helper)
        let expected = keg.appendingPathComponent("TouchGlass.app").resolvingSymlinksInPath().path
        #expect(HostLauncher.defaultTarget(executablePath: linkedHelper.path) == expected)
    }
}
