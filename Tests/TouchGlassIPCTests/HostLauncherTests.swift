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
}
