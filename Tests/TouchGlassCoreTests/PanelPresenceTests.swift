import Testing
@testable import TouchGlassCore

@Suite struct PanelPresenceTests {
    @Test func onScreenNeedsNothing() {
        var presence = PanelPresence()
        #expect(presence.check(expectedOnScreen: true, onScreen: true) == .none)
        #expect(presence.failures == 0)
    }

    @Test func aPanelThatShouldBeHiddenIsNeverChecked() {
        var presence = PanelPresence()
        #expect(presence.check(expectedOnScreen: false, onScreen: false) == .none)
        #expect(presence.check(expectedOnScreen: false, onScreen: true) == .none)
        #expect(presence.failures == 0)
    }

    @Test func failuresClimbTheLadder() {
        var presence = PanelPresence()
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .reorder)
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .rebuild)
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .giveUp)
        #expect(presence.gaveUp)
    }

    @Test func afterGivingUpNothingHappensUntilReset() {
        var presence = PanelPresence()
        for _ in 0..<3 { _ = presence.check(expectedOnScreen: true, onScreen: false) }
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .none)
        #expect(presence.check(expectedOnScreen: true, onScreen: true) == .none)
        presence.reset()
        #expect(!presence.gaveUp)
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .reorder)
    }

    @Test func aSuccessStartsTheLadderOver() {
        var presence = PanelPresence()
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .reorder)
        #expect(presence.check(expectedOnScreen: true, onScreen: true) == .none)
        #expect(presence.failures == 0)
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .reorder)
    }

    @Test func resetClearsFailures() {
        var presence = PanelPresence()
        _ = presence.check(expectedOnScreen: true, onScreen: false)
        presence.reset()
        #expect(presence.failures == 0)
        #expect(presence.check(expectedOnScreen: true, onScreen: false) == .reorder)
    }
}
