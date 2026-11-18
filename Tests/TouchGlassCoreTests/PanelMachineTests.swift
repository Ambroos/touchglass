import Foundation
import Testing
@testable import TouchGlassCore

@Suite struct PanelMachineTests {
    let wait = TouchWait.detected(operation: .sign, cardSerial: "12345678", now: Date(timeIntervalSince1970: 1000))

    @Test func firstShowOpensWithEntrance() {
        var machine = PanelMachine()
        let effects = machine.handle(.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))))
        #expect(effects.contains(.open(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678")))))
        #expect(effects.contains(.setKey(true)))
    }

    @Test func touchOnlyPanelNeverTakesKey() {
        var machine = PanelMachine()
        #expect(machine.handle(.show(.touchWait(wait))).contains(.setKey(false)))
        #expect(machine.handle(.show(.success(.sign))).contains(.setKey(false)))
    }

    @Test func pinToTouchUpdatesInPlaceAndKeepsKey() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))))
        let effects = machine.handle(.show(.touchWait(wait)))
        #expect(effects.contains(.update(.touchWait(wait))))
        #expect(effects.contains(.setKey(true)))
        _ = machine.handle(.show(.success(.sign)))
        #expect(machine.holdsKey)
        _ = machine.handle(.dismiss)
        // A new panel starts without focus again.
        #expect(machine.handle(.show(.touchWait(wait))).contains(.setKey(false)))
        #expect(effects.contains(.play(.touchStart)))
        #expect(effects.contains(.startEscalation(wait)))
    }

    @Test func hiddenTouchPanelStaysHiddenButKeepsSounds() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.touchWait(wait)))
        #expect(machine.handle(.userHid) == [.close])
        let effects = machine.handle(.show(.failure(.touchTimeout(seconds: 15))))
        #expect(!effects.contains { if case .update = $0 { true } else { false } })
        #expect(effects.contains(.play(.failure)))
        #expect(!machine.isVisible)
    }

    @Test func wrongPINIsTerminalWithBeep() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.verifying(PinRequest(operation: .sign, cardSerial: "12345678"))))
        let effects = machine.handle(.show(.failure(.wrongPIN)))
        #expect(effects.contains(.play(.rejected)))
        #expect(effects.contains(.scheduleAutoClose(after: TouchTiming.errorHold)))
    }

    @Test func failureReleasesTheKeyboard() {
        var machine = PanelMachine()
        let request = PinRequest(operation: .sign, cardSerial: "12345678")
        _ = machine.handle(.show(.pinEntry(request)))
        _ = machine.handle(.show(.verifying(request)))
        let effects = machine.handle(.show(.failure(.wrongPIN)))
        #expect(effects.contains(.setKey(false)))
        #expect(effects.contains(.scheduleAutoClose(after: TouchTiming.errorHold)))
        #expect(!machine.holdsKey)
        // The next prompt takes the keyboard again.
        #expect(machine.handle(.show(.pinEntry(request))).contains(.setKey(true)))
    }

    @Test func labelUpdateLeavesFocusAndSoundsAlone() {
        var machine = PanelMachine()
        let pin = PinRequest(operation: .sign, cardSerial: "12345678", promptID: "r1")
        _ = machine.handle(.show(.pinEntry(pin)))
        var labelled = pin
        labelled.client = "git commit · example"
        #expect(machine.handle(.show(.pinEntry(labelled))) == [.cancelAutoClose, .update(.pinEntry(labelled)), .stopEscalation])

        // A passphrase error plays the alert once, not again when the label arrives.
        let rejected = PassphraseRequest(description: "Unlock key", error: "Bad passphrase", promptID: "p1")
        #expect(machine.handle(.show(.passphrase(rejected))).contains(.play(.rejected)))
        var rejectedLabelled = rejected
        rejectedLabelled.client = "gpg"
        let effects = machine.handle(.show(.passphrase(rejectedLabelled)))
        #expect(!effects.contains(.play(.rejected)))
        #expect(!effects.contains { if case .setKey = $0 { true } else { false } })
    }

    @Test func successAutoClosesAndRearmsWithTink() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.touchWait(wait)))
        #expect(machine.handle(.show(.success(.sign))).contains(.scheduleAutoClose(after: TouchTiming.successHold)))
        let rearm = machine.handle(.show(.touchWait(wait)))
        #expect(rearm.contains(.play(.touchStart)))
        #expect(rearm.contains(.update(.touchWait(wait))))
        #expect(machine.handle(.dismiss).contains(.close))
        #expect(machine.state == nil)
    }

    @Test func userHidOnlyAppliesToTouch() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))))
        #expect(machine.handle(.userHid).isEmpty)
    }
}

@Suite struct CopyTests {
    @Test func countdownRoundsUpAndSingularises() {
        #expect(Copy.countdown(remaining: 11.2) == "12 seconds left")
        #expect(Copy.countdown(remaining: 0.3) == "1 second left")
    }

    @Test func attemptsLine() {
        #expect(Copy.attemptsLine(3) == nil)
        #expect(Copy.attemptsLine(2) == "2 attempts left")
        #expect(Copy.attemptsLine(1) == "1 attempt left. A wrong PIN blocks the card.")
    }

    @Test func escalationPhases() {
        #expect(EscalationPhase.at(elapsed: 4.9) == .calm)
        #expect(EscalationPhase.at(elapsed: 5) == .reminder)
        #expect(EscalationPhase.at(elapsed: 12) == .urgent)
        #expect(Escalation.rippleProgress(elapsed: 0) == 0)
        #expect(Escalation.rippleProgress(elapsed: 1.5) == nil)
        #expect(Escalation.rippleProgress(elapsed: 5.6)! > 0.49)
    }

    @Test func touchWaitStartsSlightlyBelowFull() {
        let now = Date()
        let wait = TouchWait.detected(operation: .decrypt, cardSerial: "12345678", now: now)
        #expect(wait.fractionRemaining(at: now) < 1)
        #expect(wait.remaining(at: now.addingTimeInterval(20)) == 0)
    }
}

@Suite struct HostSettingsTests {
    @Test func parsesKeysCommentsAndBadValues() {
        let settings = HostSettings.parse("""
            # comment
            appearance = smoked
            unknown = 1
            """)
        #expect(settings == HostSettings(appearance: .smoked))
        #expect(HostSettings().appearance == .readable)
        #expect(HostSettings.parse("appearance = sparkly") == HostSettings())
        #expect(HostSettings.load(path: "/nonexistent/host.conf") == HostSettings())
    }
}
