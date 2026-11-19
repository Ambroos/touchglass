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
        #expect(machine.handle(.dismiss).contains(.scheduleClose(after: TouchTiming.closeGrace)))
        #expect(machine.state == nil)
        #expect(machine.handle(.closeGraceFired) == [.close])
    }

    // MARK: Close grace

    @Test func dismissAloneClosesAfterTheGrace() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.touchWait(wait)))
        let dismissed = machine.handle(.dismiss)
        #expect(dismissed == [.cancelAutoClose, .stopEscalation, .scheduleClose(after: TouchTiming.closeGrace)])
        #expect(!dismissed.contains(.close))
        #expect(machine.lingering == .touchWait(wait))
        #expect(machine.handle(.closeGraceFired) == [.close])
        #expect(machine.lingering == nil)
        // A late timer after the panel closed does nothing.
        #expect(machine.handle(.closeGraceFired).isEmpty)
    }

    /// A second signature, or a push after a commit: the next touch wait arrives after the success hold,
    /// inside the grace, and replaces the success in place.
    @Test func successThenNextTouchWithinTheGrace() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.touchWait(wait)))
        _ = machine.handle(.show(.success(.sign)))
        #expect(machine.handle(.autoCloseFired).contains(.scheduleClose(after: TouchTiming.closeGrace)))
        let next = TouchWait.detected(operation: .sshLogin, cardSerial: "12345678", now: Date(timeIntervalSince1970: 1002))
        let effects = machine.handle(.show(.touchWait(next)))
        #expect(effects.contains(.cancelClose))
        #expect(effects.contains(.update(.touchWait(next))))
        #expect(!effects.contains(.open(.touchWait(next))))
        #expect(effects.contains(.setKey(false)))
        #expect(effects.contains(.play(.touchStart)))
        #expect(machine.lingering == nil)
        // The cancelled grace timer can still fire if it was already queued; it changes nothing.
        #expect(machine.handle(.closeGraceFired).isEmpty)
        #expect(machine.isVisible)
    }

    /// A PIN prompt that no operation tied to the panel ends; the proxy reports the touch wait
    /// `detectionThreshold` later, which is inside the grace.
    @Test func promptEndedThenTouchWaitShortlyAfter() {
        #expect(TouchTiming.closeGrace > TouchTiming.detectionThreshold)
        var machine = PanelMachine()
        let request = PinRequest(operation: .sign, cardSerial: "12345678")
        _ = machine.handle(.show(.pinEntry(request)))
        #expect(machine.holdsKey)
        _ = machine.handle(.dismiss)
        let effects = machine.handle(.show(.touchWait(wait)))
        #expect(effects.contains(.update(.touchWait(wait))))
        #expect(effects.contains(.cancelClose))
        // The panel starts over for focus, as if it had opened: a touch wait never takes the keyboard.
        #expect(effects.contains(.setKey(false)))
        #expect(!machine.holdsKey)
    }

    @Test func failureThenNextPromptReplacesIt() {
        var machine = PanelMachine()
        let request = PinRequest(operation: .sign, cardSerial: "12345678")
        _ = machine.handle(.show(.verifying(request)))
        _ = machine.handle(.show(.failure(.wrongPIN)))
        // The next prompt while the error still shows: a plain update, as before.
        var effects = machine.handle(.show(.pinEntry(request)))
        #expect(effects.contains(.update(.pinEntry(request))))
        #expect(effects.contains(.setKey(true)))

        // And after the error auto-closed, within the grace.
        _ = machine.handle(.show(.failure(.wrongPIN)))
        _ = machine.handle(.autoCloseFired)
        effects = machine.handle(.show(.pinEntry(request)))
        #expect(effects.contains(.cancelClose))
        #expect(effects.contains(.update(.pinEntry(request))))
        #expect(effects.contains(.setKey(true)))
    }

    /// A panel the user hid is off screen already; dismissing it schedules nothing.
    @Test func dismissingAHiddenPanelSchedulesNoClose() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.touchWait(wait)))
        _ = machine.handle(.userHid)
        #expect(machine.handle(.dismiss) == [.cancelAutoClose, .stopEscalation])
        #expect(machine.lingering == nil)
        #expect(machine.handle(.show(.touchWait(wait))).contains(.open(.touchWait(wait))))
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

    @Test func escalationScalesWithTheTouchTimeout() {
        #expect(Escalation.cues().map(\.at) == [5, 10, 10, 12.5])
        #expect(Escalation.cues(duration: 60).map(\.at) == [20, 40, 40, 50])
        #expect(Escalation.cues(duration: 6).map(\.at) == [2, 4, 4, 5])
        #expect(EscalationPhase.at(elapsed: 10, duration: 60) == .calm)
        #expect(EscalationPhase.at(elapsed: 20, duration: 60) == .reminder)
        #expect(EscalationPhase.at(elapsed: 45, duration: 60) == .urgent)
        #expect(Escalation.rippleProgress(elapsed: 20, touchDuration: 60) == 0)
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

/// The layout each state asks for. The view centres a result's glyph, title and message as one group.
@Suite struct PresentationLayoutTests {
    let wait = TouchWait.detected(operation: .sign, cardSerial: "12345678")

    @Test func resultsAreCentredGroupsWithoutControls() {
        let results: [PanelState] = [.success(.sign), .success(.sshLogin), .failure(.wrongPIN), .failure(.touchTimeout(seconds: 15)), .failure(.cardRemoved)]
        for state in results {
            let presentation = PanelPresentation(state)
            #expect(presentation.centresContent)
            #expect(presentation.controls == .none)
            #expect(!presentation.reservesClientLine)
        }
    }

    @Test func promptsAndTheTouchStepAreNotCentred() {
        let states: [PanelState] = [.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678")), .touchWait(wait), .message(MessageRequest(title: "t", detail: "d"))]
        for state in states {
            #expect(!PanelPresentation(state).centresContent)
        }
    }

    /// The touch ring and the result have different layouts, so the step crossfades in place instead
    /// of moving the ring.
    @Test func successIsItsOwnLayoutGroup() {
        #expect(PanelPresentation(.success(.sign)).layoutGroup != PanelPresentation(.touchWait(wait)).layoutGroup)
        #expect(PanelPresentation(.success(.sign)).stage == .ring(nil, completed: true))
    }
}
