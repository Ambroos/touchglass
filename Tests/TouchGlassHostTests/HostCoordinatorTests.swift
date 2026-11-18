import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

@Suite struct HostCoordinatorTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let pinentry: ConnectionID = 2
    let cardDescription = "Please unlock the card\n\nNumber: 12 345 678\nHolder: \nCounter: 7"

    func panelEvents(_ outputs: [HostOutput]) -> [PanelEvent] {
        outputs.compactMap { if case .panel(let event) = $0 { event } else { nil } }
    }

    func start(_ coordinator: inout HostCoordinator, conn: String = "100:p", op: TouchGlassIPC.OperationKind = .sign) {
        _ = coordinator.handle(.opStart(OpStart(conn: conn, op: op, slot: 1, serial: "D2760001240103040006123456780000", at: now.timeIntervalSince1970)), from: proxy, now: now)
    }

    @Test func touchOnlyOperationShowsTouchThenSuccess() throws {
        var coordinator = HostCoordinator()
        start(&coordinator)
        let shown = panelEvents(coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", timeoutMs: 15_000, at: now.timeIntervalSince1970)), from: proxy, now: now.addingTimeInterval(0.4)))
        guard case .show(.touchWait(let wait)) = try #require(shown.first) else {
            Issue.record("expected a touch wait, got \(shown)")
            return
        }
        #expect(wait.operation == .sign)
        #expect(wait.cardSerial == "12345678")
        #expect(wait.deadline == now.addingTimeInterval(15))
        #expect(panelEvents(coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)) == [.show(.success(.sign))])
    }

    @Test func pinThenVerifyingThenTouchThenSuccess() throws {
        var coordinator = HostCoordinator()
        start(&coordinator, op: .auth)
        _ = coordinator.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        let desc = cardDescription + "\nRemaining attempts: 2"
        let prompt = panelEvents(coordinator.handle(.getPin(GetPin(id: "r1", desc: desc, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now))
        #expect(prompt == [.show(.pinEntry(PinRequest(operation: .sshLogin, cardSerial: "12345678", attemptsLeft: 2)))])

        let submitted = coordinator.handle(.submit("975310"))
        #expect(submitted.contains(.reply(pinentry, .pin(PinReply(id: "r1", secret: Data("975310".utf8))))))
        #expect(panelEvents(submitted) == [.show(.verifying(PinRequest(operation: .sshLogin, cardSerial: "12345678", attemptsLeft: 2)))])
        // The secret never shows up in a printed output.
        #expect(!"\(submitted)".contains("975310"))

        // The pinentry's request ends; the panel waits for the card.
        #expect(coordinator.handle(.dismiss(RequestRef(id: "r1")), from: pinentry, now: now).isEmpty)
        #expect(coordinator.connectionClosed(pinentry).isEmpty)

        let touch = panelEvents(coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: now.timeIntervalSince1970 + 1)), from: proxy, now: now.addingTimeInterval(1.4)))
        guard case .show(.touchWait(let wait)) = touch.first else {
            Issue.record("expected a touch wait, got \(touch)")
            return
        }
        #expect(wait.operation == .sshLogin)
        #expect(panelEvents(coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)) == [.show(.success(.sshLogin))])
    }

    @Test func wrongPINIsTerminal() {
        var coordinator = HostCoordinator()
        start(&coordinator)
        _ = coordinator.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        _ = coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now)
        _ = coordinator.handle(.submit("000000"))
        #expect(panelEvents(coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .badPin)), from: proxy, now: now)) == [.show(.failure(.wrongPIN))])
    }

    @Test func errorCodesMapToFailures() {
        let scd = 6 << 24
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .error, code: scd | 130)) == .failure(.pinBlocked))
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .error, code: scd | 110)) == .failure(.cardRemoved))
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .error, code: scd | 62)) == .failure(.touchTimeout(seconds: 15)))
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .error, code: scd | 99)) == .silent)
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .timeout)) == .failure(.touchTimeout(seconds: 15)))
        #expect(HostCoordinator.outcome(OpEnd(conn: "c", result: .cancelled)) == .silent)
    }

    @Test func pinNeededAfterTouchWaitReplacesTheTouchPanel() {
        var coordinator = HostCoordinator()
        start(&coordinator)
        _ = coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: now.timeIntervalSince1970)), from: proxy, now: now)
        _ = coordinator.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        let prompt = panelEvents(coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now))
        #expect(prompt == [.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678")))])
    }

    @Test func queuedTouchWaitRearmsAfterTheFirstOperation() throws {
        var coordinator = HostCoordinator()
        start(&coordinator, conn: "100:p")
        start(&coordinator, conn: "100:s1", op: .decrypt)
        _ = coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: now.timeIntervalSince1970)), from: proxy, now: now)
        #expect(coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:s1", at: now.timeIntervalSince1970)), from: proxy, now: now).isEmpty)

        let ended = coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        #expect(ended == [.panel(.show(.success(.sign))), .schedule(after: HostCoordinator.rearmAfterSuccess, .rearm)])

        let later = now.addingTimeInterval(3)
        let rearmed = panelEvents(coordinator.fire(.rearm, now: later))
        guard case .show(.touchWait(let wait)) = try #require(rearmed.first) else {
            Issue.record("expected a touch wait, got \(rearmed)")
            return
        }
        #expect(wait.operation == .decrypt)
        #expect(wait.deadline == later.addingTimeInterval(TouchTiming.cardTimeout - TouchTiming.detectionThreshold))
    }

    @Test func operationsWithoutAPanelEndSilently() {
        var coordinator = HostCoordinator()
        start(&coordinator)
        #expect(coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now).isEmpty)
    }

    @Test func passphraseRetryShakesAndDismissCloses() {
        var coordinator = HostCoordinator()
        let first = panelEvents(coordinator.handle(.getPin(GetPin(id: "p1", desc: "Unlock key")), from: pinentry, now: now))
        #expect(first == [.show(.passphrase(PassphraseRequest(description: "Unlock key")))])
        #expect(coordinator.handle(.submit("wrong")) == [.reply(pinentry, .pin(PinReply(id: "p1", secret: Data("wrong".utf8))))])
        let retry = coordinator.handle(.getPin(GetPin(id: "p2", desc: "Unlock key", error: "Bad Passphrase (try 2 of 3)")), from: pinentry, now: now)
        #expect(retry == [.panel(.show(.passphrase(PassphraseRequest(description: "Unlock key", error: "Bad Passphrase (try 2 of 3)")))), .shakeField])
        _ = coordinator.handle(.submit("right"))
        #expect(coordinator.handle(.dismiss(RequestRef(id: "p2")), from: pinentry, now: now) == [.panel(.dismiss)])
    }

    @Test func cancelRepliesAndCloses() {
        var coordinator = HostCoordinator()
        _ = coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now)
        #expect(coordinator.handle(.cancel) == [.reply(pinentry, .cancelled(RequestRef(id: "r1"))), .panel(.dismiss)])
    }

    @Test func secondPromptWhileOneWaitsFallsBack() {
        var coordinator = HostCoordinator()
        _ = coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now)
        #expect(coordinator.handle(.confirm(Confirm(id: "c1", desc: "Allow?")), from: 3, now: now) == [.reply(3, .fallback(RequestRef(id: "c1")))])
    }

    @Test func confirmPromptsAndAnswers() {
        var coordinator = HostCoordinator()
        let shown = panelEvents(coordinator.handle(.confirm(Confirm(id: "c1", desc: "Please insert the card with serial number:\n\n12345678", ok: "_OK", cancel: "_Cancel")), from: pinentry, now: now))
        #expect(shown == [.show(.confirm(ConfirmRequest(purpose: .insertCard, title: "Insert your YubiKey", detail: "Please insert the card with serial number:\n\n12345678")))])
        #expect(coordinator.handle(.confirm) == [.reply(pinentry, .confirmed(RequestRef(id: "c1"))), .panel(.dismiss)])
        #expect(coordinator.handle(.confirm(Confirm(id: "c2", desc: "Three ways", notok: "No")), from: pinentry, now: now) == [.reply(pinentry, .fallback(RequestRef(id: "c2")))])
    }

    @Test func closedConnectionWithdrawsItsPrompt() {
        var coordinator = HostCoordinator()
        _ = coordinator.handle(.message(TouchGlassIPC.MessageRequest(id: "m1", desc: "Key added\nDetails")), from: pinentry, now: now)
        #expect(coordinator.connectionClosed(proxy).isEmpty)
        #expect(coordinator.connectionClosed(pinentry) == [.panel(.dismiss)])
    }

    @Test func verifyingGivesUpWithoutCardEvents() {
        var coordinator = HostCoordinator()
        _ = coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now)
        let submitted = coordinator.handle(.submit("123456"))
        #expect(submitted.contains(.schedule(after: HostCoordinator.verifyTimeout, .verifyWatchdog(requestID: "r1"))))
        // No operation is tied to this PIN, so the end of the request closes the panel.
        #expect(coordinator.handle(.dismiss(RequestRef(id: "r1")), from: pinentry, now: now) == [.panel(.dismiss)])
        #expect(coordinator.fire(.verifyWatchdog(requestID: "r1"), now: now).isEmpty)
    }

    @Test func serialsAndAttempts() {
        #expect(HostCoordinator.displaySerial("D2760001240103040006123456780000") == "12345678")
        #expect(HostCoordinator.displaySerial("12 345 678") == "12345678")
        #expect(HostCoordinator.displaySerial(nil) == "")
        #expect(HostCoordinator.attemptsLeft(in: "Remaining attempts: 1") == 1)
        #expect(HostCoordinator.attemptsLeft(in: "No count here") == nil)
        #expect(HostCoordinator.split(nil, "Title line\nRest of it") == ("Title line", "Rest of it"))
        #expect(HostCoordinator.label("_Allow", default: "OK") == "Allow")
    }
}
