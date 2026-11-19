import Testing
@testable import TouchGlassCore

@Suite struct TouchPolicyTests {
    @Test func uifBytes() {
        #expect(TouchPolicy(uif: 0x00) == .off)
        #expect(TouchPolicy(uif: 0x01) == .on)
        #expect(TouchPolicy(uif: 0x02) == .fixed)
        #expect(TouchPolicy(uif: 0x03) == .cached)
        #expect(TouchPolicy(uif: 0x04) == .cachedFixed)
        #expect(TouchPolicy(uif: 0x05) == nil)
        #expect(TouchPolicy(uif: 0x20) == nil)
        #expect(TouchPolicy(uif: 0xFF) == nil)
        for policy in TouchPolicy.allCases { #expect(TouchPolicy(uif: policy.uif) == policy) }
    }

    @Test func slotsPerOperation() {
        #expect(OperationKind.sign.cardSlot == 1)
        #expect(OperationKind.decrypt.cardSlot == 2)
        #expect(OperationKind.sshLogin.cardSlot == 3)
        #expect(OperationKind.unknown.cardSlot == nil)
    }

    @Test func autoFollowsThePolicy() {
        func handling(_ policy: TouchPolicy?) -> TouchHandling {
            TouchTiming.handling(setting: .auto, policy: policy)
        }
        #expect(handling(.cached) == .cacheWindow(15))
        #expect(handling(.cachedFixed) == .cacheWindow(15))
        #expect(handling(.on) == .everyTime)
        #expect(handling(.fixed) == .everyTime)
        #expect(handling(.off) == .noTouch)
        // Unknown: the default from before TouchGlass learned policies.
        #expect(handling(nil) == .cacheWindow(15))
    }

    @Test func offShowsLaterThanTheCacheWindow() {
        #expect(TouchTiming.offDetectionThreshold == 3)
        #expect(TouchTiming.offDetectionThreshold > TouchTiming.cachedDetectionThreshold)
    }

    @Test func anExplicitSettingWins() {
        for policy in [TouchPolicy.off, .on, .fixed, .cached, nil] {
            #expect(TouchTiming.handling(setting: 30, policy: policy) == .cacheWindow(30))
            #expect(TouchTiming.handling(setting: .seconds(15), policy: policy) == .cacheWindow(15))
            #expect(TouchTiming.handling(setting: 0, policy: policy) == .everyTime)
        }
    }

    @Test func settingLiterals() {
        #expect(TouchCacheSetting.auto.fixedSeconds == nil)
        #expect((0 as TouchCacheSetting) == .seconds(0))
        #expect((2.5 as TouchCacheSetting).fixedSeconds == 2.5)
    }

    @Test func parsesTheSetting() {
        #expect(HostSettings.parse("").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = auto").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = 15\ntouch-cache = auto").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = 0").touchCache == 0)
        #expect(HostSettings.parse("touch-cache = 601").touchCache == .auto)
    }
}
