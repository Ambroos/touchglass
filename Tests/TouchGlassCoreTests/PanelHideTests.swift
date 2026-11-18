import Foundation
import Testing
@testable import TouchGlassCore

/// A hide covers one touch wait and its result, never a later prompt or operation.
@Suite struct PanelHideTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func touch(_ operation: OperationKind = .sign, at offset: TimeInterval = 0) -> PanelState {
        .touchWait(TouchWait(operation: operation, cardSerial: "12345678", deadline: now.addingTimeInterval(offset + 15), shownAt: now.addingTimeInterval(offset)))
    }

    func hiddenTouch() -> PanelMachine {
        var machine = PanelMachine()
        _ = machine.handle(.show(touch()))
        _ = machine.handle(.userHid)
        return machine
    }

    @Test func pinPromptAfterHiddenTouchAndTimeoutShows() {
        var machine = hiddenTouch()
        _ = machine.handle(.show(.failure(.touchTimeout(seconds: 15))))
        #expect(!machine.isVisible)

        let pin = PanelState.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))
        let effects = machine.handle(.show(pin))
        #expect(effects.contains(.open(pin)))
        #expect(effects.contains(.setKey(true)))
        #expect(machine.isVisible)
        #expect(!machine.hiddenByUser)
    }

    @Test func promptDirectlyAfterHiddenTouchShows() {
        var machine = hiddenTouch()
        let passphrase = PanelState.passphrase(PassphraseRequest(description: "Passphrase"))
        #expect(machine.handle(.show(passphrase)).contains(.open(passphrase)))
        #expect(machine.isVisible)
    }

    @Test func nextOperationAfterHiddenSuccessShows() {
        var machine = hiddenTouch()
        _ = machine.handle(.show(.success(.sign)))
        #expect(!machine.isVisible)

        let next = touch(.sshLogin, at: 0.6)
        #expect(machine.handle(.show(next)).contains(.open(next)))
        #expect(machine.isVisible)
    }

    @Test func sameTouchWaitStaysHidden() {
        var machine = hiddenTouch()
        let renewed = touch(at: 1)
        let effects = machine.handle(.show(renewed))
        #expect(!effects.contains(.update(renewed)))
        #expect(!effects.contains(.open(renewed)))
        #expect(!machine.isVisible)
    }

    @Test func reopeningAfterAHideResetsKeyHolding() {
        var machine = PanelMachine()
        _ = machine.handle(.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))))
        _ = machine.handle(.show(touch()))
        #expect(machine.holdsKey)
        _ = machine.handle(.userHid)
        _ = machine.handle(.show(.success(.sign)))

        let next = touch(.sshLogin, at: 0.6)
        let effects = machine.handle(.show(next))
        #expect(effects.contains(.open(next)))
        #expect(effects.contains(.setKey(false)))
        #expect(!machine.holdsKey)
    }

    @Test func otherOperationsTouchWaitShows() {
        var machine = hiddenTouch()
        let other = touch(.decrypt, at: 1)
        #expect(machine.handle(.show(other)).contains(.open(other)))
        #expect(machine.isVisible)
    }
}
