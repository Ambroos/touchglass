import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// Operations and prompts that end without the message the coordinator normally waits for.
@Suite struct HostCoordinatorLifecycleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let pinentry: ConnectionID = 2
    let cardDescription = "Please unlock the card\n\nNumber: 12 345 678\nHolder: \nCounter: 7"

    func panelEvents(_ outputs: [HostOutput]) -> [PanelEvent] {
        outputs.compactMap { if case .panel(let event) = $0 { event } else { nil } }
    }

    func timers(_ outputs: [HostOutput]) -> [HostTimer] {
        outputs.compactMap { if case .schedule(_, let timer) = $0 { timer } else { nil } }
    }

    func isTouch(_ outputs: [HostOutput]) -> Bool {
        panelEvents(outputs).contains { if case .show(.touchWait) = $0 { true } else { false } }
    }

    func start(_ c: inout HostCoordinator, conn: String, from connection: ConnectionID? = nil) {
        _ = c.handle(.opStart(OpStart(conn: conn, op: .sign, slot: 1, serial: "D2760001240103040006123456780000", at: now.timeIntervalSince1970)), from: connection ?? proxy, now: now)
    }

    func touch(_ c: inout HostCoordinator, conn: String, from connection: ConnectionID? = nil, at time: Date? = nil) -> [HostOutput] {
        let time = time ?? now
        return c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: conn, at: time.timeIntervalSince1970)), from: connection ?? proxy, now: time)
    }

    // MARK: H2: lost op_end

    @Test func closedProxyConnectionEndsItsOperations() {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        #expect(isTouch(touch(&c, conn: "100:p")))

        #expect(panelEvents(c.connectionClosed(proxy)) == [.dismiss])
        #expect(c.operations.isEmpty)

        // A later proxy's operation shows and ends normally.
        let later = now.addingTimeInterval(3600)
        start(&c, conn: "200:p", from: 5)
        #expect(isTouch(touch(&c, conn: "200:p", from: 5, at: later)))
        #expect(panelEvents(c.handle(.opEnd(OpEnd(conn: "200:p", result: .ok)), from: 5, now: later)) == [.show(.success(.sign))])
    }

    @Test func closedProxyConnectionLeavesOtherProxiesAlone() {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        start(&c, conn: "200:p", from: 5)
        #expect(isTouch(touch(&c, conn: "200:p", from: 5)))
        #expect(c.connectionClosed(proxy).isEmpty)
        #expect(c.operations["200:p"] != nil)
        #expect(c.shown == .touch(operation: "200:p"))
    }

    @Test func closedProxyConnectionShowsTheNextQueuedTouch() {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        start(&c, conn: "200:s1", from: 5)
        _ = touch(&c, conn: "100:p")
        #expect(touch(&c, conn: "200:s1", from: 5).isEmpty)

        let closed = c.connectionClosed(proxy)
        #expect(panelEvents(closed) == [.dismiss])
        #expect(timers(closed) == [.rearm])
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(1))))
    }

    @Test func touchWaitExpiresAfterDeadlineAndGrace() throws {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        let shown = touch(&c, conn: "100:p")
        let expiry = try #require(shown.compactMap { output -> (TimeInterval, HostTimer)? in
            if case .schedule(let delay, let timer) = output, case .touchExpired = timer { (delay, timer) } else { nil }
        }.first)
        // The proxy reports `at`, so the deadline is the card's 15 s from then; the grace follows.
        #expect(expiry.0 == 15 + HostCoordinator.touchExpiryGrace)

        #expect(panelEvents(c.fire(expiry.1, now: now.addingTimeInterval(17))) == [.dismiss])
        #expect(c.operations.isEmpty)
        #expect(c.shown == nil)
    }

    @Test func expiryIsIgnoredOnceTheOperationMovedOn() throws {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        let timer = try #require(timers(touch(&c, conn: "100:p")).first)
        // A false start: the card asks for the PIN, so the touch deadline no longer applies.
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        #expect(c.fire(timer, now: now.addingTimeInterval(17)).isEmpty)
        #expect(c.operations["100:p"] != nil)

        // An operation that ended normally is not ended again.
        var d = HostCoordinator()
        start(&d, conn: "100:p")
        let other = try #require(timers(touch(&d, conn: "100:p")).first)
        _ = d.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        #expect(d.fire(other, now: now.addingTimeInterval(17)).isEmpty)
        #expect(d.shown == .result)
    }

    @Test func expiredTouchShowsTheNextQueuedTouch() throws {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        start(&c, conn: "100:s1")
        let timer = try #require(timers(touch(&c, conn: "100:p")).first)
        #expect(touch(&c, conn: "100:s1").isEmpty)
        let expired = c.fire(timer, now: now.addingTimeInterval(17))
        #expect(timers(expired) == [.rearm])
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(18))))
    }

    // MARK: H1 through the coordinator

    @Test func hiddenTouchThenTimeoutThenPINPromptShows() {
        var c = HostCoordinator()
        var machine = PanelMachine()
        func apply(_ outputs: [HostOutput]) { panelEvents(outputs).forEach { _ = machine.handle($0) } }

        start(&c, conn: "100:p")
        apply(touch(&c, conn: "100:p"))
        apply(c.handle(.hide))
        #expect(!machine.isVisible)
        apply(c.handle(.opEnd(OpEnd(conn: "100:p", result: .timeout)), from: proxy, now: now.addingTimeInterval(15)))

        // The user reruns the command within the error hold; the card wants the PIN again.
        start(&c, conn: "100:p")
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now.addingTimeInterval(16))
        apply(c.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now.addingTimeInterval(16)))
        #expect(machine.isVisible)
        guard case .pinEntry = machine.state else {
            Issue.record("expected a PIN prompt, got \(String(describing: machine.state))")
            return
        }
    }

    // MARK: M4: queued touch behind a prompt

    func pinPromptWithQueuedTouch() -> HostCoordinator {
        var c = HostCoordinator()
        start(&c, conn: "100:p")
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        _ = c.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"))), from: pinentry, now: now)
        start(&c, conn: "100:s1")
        #expect(touch(&c, conn: "100:s1").isEmpty)
        return c
    }

    @Test func cancelledPromptShowsTheQueuedTouch() {
        var c = pinPromptWithQueuedTouch()
        let cancelled = c.handle(.cancel)
        #expect(timers(cancelled) == [.rearm])
        _ = c.handle(.opEnd(OpEnd(conn: "100:p", result: .cancelled)), from: proxy, now: now)
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(1))))
    }

    @Test func withdrawnPromptShowsTheQueuedTouch() {
        var c = pinPromptWithQueuedTouch()
        #expect(timers(c.handle(.dismiss(RequestRef(id: "r1")), from: pinentry, now: now)) == [.rearm])
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(1))))

        var d = pinPromptWithQueuedTouch()
        #expect(timers(d.connectionClosed(pinentry)) == [.rearm])
        #expect(isTouch(d.fire(.rearm, now: now.addingTimeInterval(1))))
    }

    @Test func confirmedMessageShowsTheQueuedTouch() {
        var c = HostCoordinator()
        _ = c.handle(.message(TouchGlassIPC.MessageRequest(id: "m1", desc: "Note")), from: pinentry, now: now)
        start(&c, conn: "100:s1")
        #expect(touch(&c, conn: "100:s1").isEmpty)
        #expect(timers(c.handle(.confirm)) == [.rearm])
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(1))))
    }

    @Test func verifyWatchdogShowsTheQueuedTouch() {
        var c = pinPromptWithQueuedTouch()
        _ = c.handle(.submit("975310"))
        let fired = c.fire(.verifyWatchdog(requestID: "r1"), now: now.addingTimeInterval(30))
        #expect(panelEvents(fired) == [.dismiss])
        #expect(timers(fired) == [.rearm])
        #expect(isTouch(c.fire(.rearm, now: now.addingTimeInterval(31))))
    }

    // MARK: L1: passphrase takeover

    @Test func anotherConnectionCannotTakeOverAPassphrasePrompt() {
        var c = HostCoordinator()
        _ = c.handle(.getPin(GetPin(id: "a1", desc: "Passphrase for key")), from: 2, now: now)
        let second = c.handle(.getPin(GetPin(id: "other", desc: "Passphrase for key", error: "Bad passphrase")), from: 3, now: now)
        #expect(second == [.reply(3, .fallback(RequestRef(id: "other")))])

        let submitted = c.handle(.submit("correct horse"))
        #expect(submitted == [.reply(2, .pin(PinReply(id: "a1", secret: Data("correct horse".utf8))))])
    }

    @Test func theOwningPinentryCanStillRetry() {
        var c = HostCoordinator()
        _ = c.handle(.getPin(GetPin(id: "a1", desc: "Passphrase for key")), from: 2, now: now)
        _ = c.handle(.submit("wrong"))
        let retry = c.handle(.getPin(GetPin(id: "a2", desc: "Passphrase for key", error: "Bad passphrase")), from: 2, now: now)
        #expect(retry.contains(.shakeField))
        #expect(c.handle(.submit("right")) == [.reply(2, .pin(PinReply(id: "a2", secret: Data("right".utf8))))])
    }
}
