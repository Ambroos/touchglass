import Foundation
import Testing
@testable import TouchGlassPanel

/// Whether tests may give the panel key status, which takes the keyboard from the frontmost app.
///
/// Off by default, because tests run while someone works at the Mac. Set `TOUCHGLASS_FOCUS_TESTS=1` to turn
/// them on; CI runners (`CI` set) have no user to disturb, so they turn them on too. While they are off, no
/// panel window in the test process can become key.
enum FocusTests {
    static let enabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["TOUCHGLASS_FOCUS_TESTS"] == "1" || environment["CI"] != nil
    }()

    /// The trait for a test that needs the panel to become key.
    static let trait = Testing.ConditionTrait.enabled(
        if: enabled,
        "Takes keyboard focus from the frontmost app; set TOUCHGLASS_FOCUS_TESTS=1 to run it"
    )

    /// Call from every suite that creates panel windows.
    @MainActor static func apply() {
        PanelWindow.refusesKey = !enabled
    }
}
