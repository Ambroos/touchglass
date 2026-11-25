import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// The touch cache window: after the card completes an operation that waited for a touch, a touch wait shows
/// only once the card command stayed silent for `cachedDetectionThreshold`, and an operation that ends before
/// that shows nothing.
@Suite struct TouchCacheTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let otherProxy: ConnectionID = 3
    let pinentry: ConnectionID = 2
    static let serial = "D2760001240103040006123456780000"

    func panelEvents(_ outputs: [HostOutput]) -> [PanelEvent] {
        outputs.compactMap { if case .panel(let event) = $0 { event } else { nil } }
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func start(_ c: inout HostCoordinator, _ conn: String, at seconds: TimeInterval, op: TouchGlassIPC.OperationKind = .sign, serial: String = serial, from connection: ConnectionID? = nil) {
        _ = c.handle(.opStart(OpStart(conn: conn, op: op, slot: 1, serial: serial, at: at(seconds).timeIntervalSince1970)), from: connection ?? proxy, now: at(seconds))
    }

    /// The proxy reports the touch wait 0.4 s after the command, with `at` set to the command's time.
    func touchWait(_ c: inout HostCoordinator, _ conn: String, commandAt seconds: TimeInterval, from connection: ConnectionID? = nil) -> [HostOutput] {
        c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: conn, at: at(seconds).timeIntervalSince1970)), from: connection ?? proxy, now: at(seconds + TouchTiming.detectionThreshold))
    }

    func end(_ c: inout HostCoordinator, _ conn: String, at seconds: TimeInterval, result: OperationResult = .ok, from connection: ConnectionID? = nil) -> [HostOutput] {
        c.handle(.opEnd(OpEnd(conn: conn, result: result)), from: connection ?? proxy, now: at(seconds))
    }

    /// One touched signature that ends at `endAt`: opens the card's touch cache window.
    func touchedSignature(_ c: inout HostCoordinator, endAt: TimeInterval = 3) {
        start(&c, "100:p", at: 0)
        _ = touchWait(&c, "100:p", commandAt: 0)
        _ = end(&c, "100:p", at: endAt)
    }

    /// Whether `outputs` is exactly one held-back touch wait for `conn`, due at `showAt` seconds.
    func isHeldBack(_ outputs: [HostOutput], _ conn: String, showAt: TimeInterval, now: TimeInterval) -> Bool {
        guard outputs.count == 1, case .schedule(let delay, .showTouch(conn, let due)) = outputs[0] else { return false }
        return abs(delay - (showAt - now)) < 1e-6 && abs(due.timeIntervalSince(at(showAt))) < 1e-6
    }

    func shownTouch(_ outputs: [HostOutput]) -> TouchGlassCore.TouchWait? {
        for case .panel(.show(.touchWait(let wait))) in outputs { return wait }
        return nil
    }

    // MARK: Inside the window

    @Test func cachedOperationInsideTheWindowShowsNothing() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5)
        #expect(isHeldBack(touchWait(&c, "100:p", commandAt: 5), "100:p", showAt: 6.5, now: 5.4))
        // The cached signature takes 0.8 s: no touch state and no result state.
        #expect(end(&c, "100:p", at: 5.8).isEmpty)
        #expect(c.fire(.showTouch(operation: "100:p", at: at(6.5)), now: at(6.5)).isEmpty)
        #expect(c.takeLog().contains(.touchSkipped(conn: "100:p", result: .ok)))
    }

    @Test func realTouchInsideTheWindowShowsAtTheLongerDelayWithAnHonestCountdown() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5)
        #expect(panelEvents(touchWait(&c, "100:p", commandAt: 5)).isEmpty)
        let shown = c.fire(.showTouch(operation: "100:p", at: at(6.5)), now: at(6.5))
        let wait = try #require(shownTouch(shown))
        // The countdown runs from the card command, not from the panel.
        #expect(wait.deadline == at(5 + TouchTiming.cardTimeout))
        #expect(wait.shownAt == at(6.5))
        #expect(shown.contains(.schedule(after: 13.5 + HostCoordinator.touchExpiryGrace, .touchExpired(operation: "100:p", deadline: at(20)))))
        #expect(panelEvents(end(&c, "100:p", at: 9)) == [.show(.success(.sign))])
    }

    @Test func aTouchWaitReportedLateShowsAtOnce() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5)
        // The event reaches the host 1.6 s after the command, past the longer delay.
        let outputs = c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: at(5).timeIntervalSince1970)), from: proxy, now: at(6.6))
        #expect(try #require(shownTouch(outputs)).deadline == at(20))
    }

    // MARK: Outside the window

    @Test func operationOutsideTheWindowShowsTheTouchAtOnce() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c, endAt: 3)
        // The window ended at 18 s.
        start(&c, "100:p", at: 18.5)
        let wait = try #require(shownTouch(touchWait(&c, "100:p", commandAt: 18.5)))
        #expect(wait.shownAt == at(18.9))
        #expect(wait.deadline == at(18.5 + TouchTiming.cardTimeout))
    }

    @Test func firstOperationShowsTheTouchAtOnce() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        start(&c, "100:p", at: 0)
        #expect(shownTouch(touchWait(&c, "100:p", commandAt: 0)) != nil)
    }

    @Test func touchCacheZeroTurnsTheWindowOff() {
        var c = HostCoordinator(touchCache: 0).verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5)
        #expect(shownTouch(touchWait(&c, "100:p", commandAt: 5)) != nil)
    }

    @Test func failedOperationDoesNotOpenTheWindow() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        start(&c, "100:p", at: 0)
        _ = touchWait(&c, "100:p", commandAt: 0)
        _ = end(&c, "100:p", at: 15, result: .timeout)
        start(&c, "100:p", at: 20)
        #expect(shownTouch(touchWait(&c, "100:p", commandAt: 20)) != nil)
    }

    @Test func cachedOperationsDoNotRestartTheWindow() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        // The touch ends at 11 s; the cache answers 20 signatures between 22 and 26 s, each in 0.11 s,
        // before the proxy reports a touch wait.
        start(&c, "100:p", at: 0)
        _ = touchWait(&c, "100:p", commandAt: 0)
        _ = end(&c, "100:p", at: 11)
        for i in 0..<20 {
            let startAt = 22 + Double(i) * 0.2
            start(&c, "100:p", at: startAt)
            #expect(end(&c, "100:p", at: startAt + 0.11).isEmpty, "operation \(i)")
        }
        #expect(c.lastTouch[Self.displaySerial] == at(11))
        _ = c.takeLog()
        // 40.5 s is 29.5 s past the touch, but less than 15 s after the last cached signature: the window has
        // closed, so the touch shows at once.
        start(&c, "100:s1", at: 40.5, op: .auth)
        let wait = try #require(shownTouch(touchWait(&c, "100:s1", commandAt: 40.5)))
        #expect(wait.shownAt == at(40.9))
        #expect(!c.takeLog().contains { if case .touchDeferred = $0 { true } else { false } })
    }

    @Test func theDeferralEndsFifteenSecondsAfterTheLastTouch() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c, endAt: 3)
        start(&c, "100:p", at: 10)
        _ = end(&c, "100:p", at: 10.1)
        // Still inside the window that the touch opened: held back.
        start(&c, "100:p", at: 17.5)
        #expect(isHeldBack(touchWait(&c, "100:p", commandAt: 17.5), "100:p", showAt: 19, now: 17.9))
        _ = end(&c, "100:p", at: 18)
        // Past it: at once, although a cached signature ended less than 15 s ago.
        start(&c, "100:p", at: 18.5)
        #expect(shownTouch(touchWait(&c, "100:p", commandAt: 18.5)) != nil)
    }

    @Test func slowCachedAnswerInsideTheWindowDoesNotRestartIt() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c, endAt: 3)
        // The proxy reports a touch wait, but the card answers 0.8 s after the command, before the panel shows.
        start(&c, "100:p", at: 5)
        _ = touchWait(&c, "100:p", commandAt: 5)
        _ = end(&c, "100:p", at: 5.8)
        #expect(c.lastTouch[Self.displaySerial] == at(3))
    }

    @Test func operationThatWaitedForATouchRestartsTheWindow() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c, endAt: 3)
        start(&c, "100:p", at: 20)
        _ = touchWait(&c, "100:p", commandAt: 20)
        _ = c.takeLog()
        _ = end(&c, "100:p", at: 23)
        #expect(c.lastTouch[Self.displaySerial] == at(23))
        #expect(c.takeLog().contains(.touchCacheRestarted(serial: Self.displaySerial, seconds: TouchTiming.touchCacheWindow)))
        start(&c, "100:p", at: 30)
        #expect(panelEvents(touchWait(&c, "100:p", commandAt: 30)).isEmpty)
    }

    @Test func touchAfterAPinRestartsTheWindow() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        start(&c, "100:p", at: 0, op: .auth)
        // A touch wait before the PIN request is a false start.
        _ = touchWait(&c, "100:p", commandAt: 0)
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: at(0.5))
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Please unlock the card", fields: CardFields(number: "12 345 678"))), from: pinentry, now: at(0.5))
        _ = c.handle(.submit("975310"))
        _ = try #require(shownTouch(touchWait(&c, "100:p", commandAt: 3)))
        _ = end(&c, "100:p", at: 5)
        #expect(c.lastTouch[Self.displaySerial] == at(5))
    }

    @Test func cachedAnswerAfterAPinDoesNotRestartTheWindow() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c, endAt: 3)
        start(&c, "100:p", at: 5, op: .auth)
        // The touch wait before the PIN request is a false start; after the PIN, the cache answers.
        _ = touchWait(&c, "100:p", commandAt: 5)
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: at(5.5))
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Please unlock the card", fields: CardFields(number: "12 345 678"))), from: pinentry, now: at(5.5))
        _ = c.handle(.submit("975310"))
        _ = end(&c, "100:p", at: 8.1)
        #expect(c.lastTouch[Self.displaySerial] == at(3))
    }

    static let displaySerial = "12345678"

    // MARK: PIN prompt

    @Test func pinThenTouchKeepsTheTouchInPlaceOfVerifying() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5, op: .auth)
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: at(5.1))
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Please unlock the card", fields: CardFields(number: "12 345 678"))), from: pinentry, now: at(5.1))
        let submitted = panelEvents(c.handle(.submit("975310")))
        guard case .show(.verifying) = try #require(submitted.first) else {
            Issue.record("expected verifying, got \(submitted)")
            return
        }
        // The agent answers the PIN at 8 s; the card waits for the touch from then on.
        let wait = try #require(shownTouch(touchWait(&c, "100:p", commandAt: 8)))
        #expect(wait.operation == .sshLogin)
        #expect(wait.shownAt == at(8.4))
        #expect(wait.deadline == at(8 + TouchTiming.cardTimeout))
    }

    @Test func pinNeededCancelsAHeldBackTouchWait() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "100:p", at: 5)
        _ = touchWait(&c, "100:p", commandAt: 5)
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: at(5.5))
        #expect(c.fire(.showTouch(operation: "100:p", at: at(6.5)), now: at(6.5)).isEmpty)
    }

    // MARK: Several proxies

    @Test func theWindowCoversEveryProxyOfTheCard() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        // A signature on one proxy's pipe session opens the window...
        touchedSignature(&c)
        // ...and an SSH login on another proxy, overlapping a third operation that waits, uses it too.
        start(&c, "200:s1", at: 4, op: .auth, from: otherProxy)
        start(&c, "100:p", at: 4.2)
        #expect(panelEvents(touchWait(&c, "200:s1", commandAt: 4, from: otherProxy)).isEmpty)
        #expect(panelEvents(touchWait(&c, "100:p", commandAt: 4.2)).isEmpty)
        #expect(end(&c, "200:s1", at: 4.7, from: otherProxy).isEmpty)
        // The second one does need a touch: it shows at 1.5 s after its own command.
        #expect(c.fire(.showTouch(operation: "200:s1", at: at(5.5)), now: at(5.5)).isEmpty)
        let wait = try #require(shownTouch(c.fire(.showTouch(operation: "100:p", at: at(5.7)), now: at(5.7))))
        #expect(wait.operation == .sign)
        #expect(wait.deadline == at(4.2 + TouchTiming.cardTimeout))
    }

    @Test func anotherCardHasItsOwnWindow() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        start(&c, "200:p", at: 5, serial: "D2760001240103040006999999990000", from: otherProxy)
        #expect(shownTouch(touchWait(&c, "200:p", commandAt: 5, from: otherProxy)) != nil)
    }

    @Test func heldBackTouchQueuesBehindAShownOne() {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        touchedSignature(&c)
        // A held-back touch wait on one proxy; meanwhile another card's touch shows.
        start(&c, "100:p", at: 5)
        _ = touchWait(&c, "100:p", commandAt: 5)
        start(&c, "200:p", at: 5.1, serial: "D2760001240103040006999999990000", from: otherProxy)
        #expect(shownTouch(touchWait(&c, "200:p", commandAt: 5.1, from: otherProxy)) != nil)
        // The held-back one comes due while that panel shows: it queues.
        #expect(c.fire(.showTouch(operation: "100:p", at: at(6.5)), now: at(6.5)).isEmpty)
        #expect(c.queuedTouch == ["100:p"])
    }

    @Test func queuedTouchInsideTheCacheWindowIsHeldBack() throws {
        var c = HostCoordinator().verifying(proxy, otherProxy, pinentry)
        start(&c, "100:p", at: 0)
        start(&c, "100:s1", at: 0.1, op: .decrypt)
        _ = touchWait(&c, "100:p", commandAt: 0)
        #expect(touchWait(&c, "100:s1", commandAt: 0.1).isEmpty)
        // The touch for the first operation ends at 3 s and opens the window; the queued one comes next.
        let ended = end(&c, "100:p", at: 3)
        #expect(ended.contains(.schedule(after: HostCoordinator.rearmAfterSuccess, .rearm)))
        let rearmed = c.fire(.rearm, now: at(3.5))
        // Counted from 3.1 s, when the panel would show without the window.
        #expect(isHeldBack(rearmed, "100:s1", showAt: 4.6, now: 3.5))
        // The cached touch answers it: nothing shows after the first operation's success.
        #expect(end(&c, "100:s1", at: 3.6).isEmpty)
        // Its touch wait was reported while it waited in line behind the first operation, not for a touch.
        #expect(c.lastTouch[Self.displaySerial] == at(3))
    }

    // MARK: Settings

    @Test func touchCacheSetting() {
        #expect(HostSettings.parse("").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = auto").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = AUTO").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = 0").touchCache == 0)
        #expect(HostSettings.parse("touch-cache = 30").touchCache == 30)
        #expect(HostSettings.parse("touch-cache = 15").touchCache == .seconds(15))
        #expect(HostSettings.parse("touch-cache = -1").touchCache == .auto)
        #expect(HostSettings.parse("touch-cache = soon").touchCache == .auto)
    }
}
