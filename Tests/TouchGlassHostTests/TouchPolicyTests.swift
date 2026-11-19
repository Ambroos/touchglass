import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// Per-slot touch timing from learned touch policies, and how the host learns them.
@Suite struct TouchPolicyTimingTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    static let serial = "D2760001240103040006123456780000"
    static let display = "12345678"
    /// Manufacturer 0005, not Yubico.
    static let otherSerial = "D2760001240103040005876543210000"
    static let gnupg = GnuPGContext(home: "/tmp/gnupg", binDir: "/opt/example/bin")

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func start(_ c: inout HostCoordinator, at seconds: TimeInterval, op: TouchGlassIPC.OperationKind = .sign, slot: Int? = 1, serial: String = serial) {
        _ = c.handle(.opStart(OpStart(conn: "100:p", op: op, slot: slot, serial: serial, at: at(seconds).timeIntervalSince1970)), from: proxy, now: at(seconds))
    }

    func touchWait(_ c: inout HostCoordinator, commandAt seconds: TimeInterval, pinpad: Bool? = nil) -> [HostOutput] {
        c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: at(seconds).timeIntervalSince1970, pinpad: pinpad)), from: proxy, now: at(seconds + TouchTiming.detectionThreshold))
    }

    func end(_ c: inout HostCoordinator, at seconds: TimeInterval, result: OperationResult = .ok) -> [HostOutput] {
        c.handle(.opEnd(OpEnd(conn: "100:p", result: result)), from: proxy, now: at(seconds))
    }

    func learn(_ c: inout HostCoordinator, _ slots: [Int: TouchPolicy], serial: String = serial) {
        c.loadPolicies([CardTouchPolicy(serial: serial, slots: slots)])
    }

    /// A touched operation that ends at 3 s, so the card's touch cache window is open until 18 s.
    func touchedOperation(_ c: inout HostCoordinator, op: TouchGlassIPC.OperationKind = .sign, slot: Int = 1, serial: String = serial) {
        start(&c, at: 0, op: op, slot: slot, serial: serial)
        _ = touchWait(&c, commandAt: 0)
        _ = end(&c, at: 3)
    }

    func shows(_ outputs: [HostOutput]) -> Bool {
        outputs.contains { if case .panel(.show(.touchWait)) = $0 { true } else { false } }
    }

    func holdsBack(_ outputs: [HostOutput]) -> Bool {
        outputs.contains { if case .schedule(_, .showTouch) = $0 { true } else { false } }
    }

    // MARK: Timing

    @Test func cachedSlotHoldsTheTouchBackInsideTheWindow() {
        for policy in [TouchPolicy.cached, .cachedFixed] {
            var c = HostCoordinator()
            learn(&c, [1: policy])
            touchedOperation(&c)
            start(&c, at: 5)
            let outputs = touchWait(&c, commandAt: 5)
            #expect(holdsBack(outputs) && !shows(outputs), "\(policy)")
        }
    }

    @Test func onSlotShowsTheTouchAtOnceInsideTheWindow() {
        for policy in [TouchPolicy.on, .fixed] {
            var c = HostCoordinator()
            learn(&c, [1: policy])
            touchedOperation(&c)
            start(&c, at: 5)
            let outputs = touchWait(&c, commandAt: 5)
            #expect(shows(outputs) && !holdsBack(outputs), "\(policy)")
        }
    }

    @Test func eachSlotFollowsItsOwnPolicy() {
        var c = HostCoordinator()
        learn(&c, [1: .cached, 3: .on])
        touchedOperation(&c)
        // An SSH login uses slot 3: at once, though the signature opened the window.
        start(&c, at: 5, op: .auth, slot: 3)
        #expect(shows(touchWait(&c, commandAt: 5)))
        _ = end(&c, at: 6)
        // Without the slot from the proxy, the kind gives it.
        start(&c, at: 8, op: .auth, slot: nil)
        #expect(shows(touchWait(&c, commandAt: 8)))
        _ = end(&c, at: 9)
        start(&c, at: 10, op: .sign, slot: nil)
        #expect(holdsBack(touchWait(&c, commandAt: 10)))
    }

    /// Whether `outputs` holds the touch wait back until `showAt` seconds.
    func heldUntil(_ outputs: [HostOutput], _ showAt: TimeInterval) -> Bool {
        outputs.contains { if case .schedule(_, .showTouch(_, let due)) = $0 { abs(due.timeIntervalSince(at(showAt))) < 1e-6 } else { false } }
    }

    @Test func offSlotShowsAnInferredTouchLate() throws {
        var c = HostCoordinator()
        learn(&c, [2: .off])
        start(&c, at: 0, op: .decrypt, slot: 2)
        let held = touchWait(&c, commandAt: 0)
        #expect(heldUntil(held, TouchTiming.offDetectionThreshold) && !shows(held))
        #expect(c.takeLog().contains {
            if case let .touchDeferredNoTouchPolicy("100:p", Self.display, 2, showIn) = $0 { abs(showIn - 2.6) < 1e-6 } else { false }
        })
        // A slow card that answers first: nothing shows.
        #expect(end(&c, at: 1.2).isEmpty)
        // A card that does wait for a touch, because its policy changed: the panel shows at 3 s, with the
        // countdown from the command.
        start(&c, at: 10, op: .decrypt, slot: 2)
        _ = touchWait(&c, commandAt: 10)
        let shown = c.fire(.showTouch(operation: "100:p", at: at(13)), now: at(13))
        let wait = try #require(shown.compactMap { if case .panel(.show(.touchWait(let w))) = $0 { w } else { nil } }.first)
        #expect(wait.deadline == at(10 + TouchTiming.cardTimeout))
        // A pinpad prompt is scdaemon's word: it shows at once.
        _ = end(&c, at: 14)
        start(&c, at: 20, op: .decrypt, slot: 2)
        #expect(shows(touchWait(&c, commandAt: 20, pinpad: true)))
    }

    /// After a PIN prompt, an `off` key still waits 3 s: the verifying state stays meanwhile.
    @Test func offSlotHoldsBackAfterAPinToo() {
        var c = HostCoordinator()
        learn(&c, [1: .off])
        start(&c, at: 0)
        _ = c.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: at(0.1))
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Please unlock the card", owner: nil)), from: 2, now: at(0.2))
        _ = c.handle(.submit("123456"))
        let outputs = c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: at(2).timeIntervalSince1970)), from: proxy, now: at(2.4))
        #expect(heldUntil(outputs, 2 + TouchTiming.offDetectionThreshold) && !shows(outputs))
    }

    @Test func offSlotDoesNotRestartTheWindow() {
        var c = HostCoordinator()
        learn(&c, [1: .cached, 2: .off])
        start(&c, at: 0, op: .decrypt, slot: 2)
        _ = end(&c, at: 0.3)
        #expect(c.lastCardUse[Self.display] == nil)
        start(&c, at: 5)
        #expect(shows(touchWait(&c, commandAt: 5)))
    }

    @Test func unknownSlotKeepsTheDefault() {
        var c = HostCoordinator()
        learn(&c, [3: .on])
        touchedOperation(&c)
        start(&c, at: 5)
        #expect(holdsBack(touchWait(&c, commandAt: 5)))
    }

    /// off, on and fixed come from the OpenPGP card specification, so they count for any card.
    @Test func otherCardsUseTheStandardPolicies() {
        var c = HostCoordinator()
        learn(&c, [1: .on, 2: .off, 3: .cached], serial: Self.otherSerial)
        touchedOperation(&c, serial: Self.otherSerial)
        start(&c, at: 5, serial: Self.otherSerial)
        #expect(shows(touchWait(&c, commandAt: 5)))
        _ = end(&c, at: 6)
        start(&c, at: 7, op: .decrypt, slot: 2, serial: Self.otherSerial)
        #expect(heldUntil(touchWait(&c, commandAt: 7), 7 + TouchTiming.offDetectionThreshold))
        _ = end(&c, at: 8)
        // cached is Yubico's value: the default window, which is the same.
        start(&c, at: 9, op: .auth, slot: 3, serial: Self.otherSerial)
        #expect(heldUntil(touchWait(&c, commandAt: 9), 9 + TouchTiming.cachedDetectionThreshold))
    }

    @Test func explicitTouchCacheOverridesThePolicy() {
        var c = HostCoordinator(touchCache: 30)
        learn(&c, [1: .on, 2: .off])
        touchedOperation(&c)
        // 25 s is past the card's 15 s, but inside the configured 30 s.
        start(&c, at: 25)
        #expect(holdsBack(touchWait(&c, commandAt: 25)))
        _ = end(&c, at: 26)
        // Inside the configured window, the off key gets the window's delay, not its own.
        start(&c, at: 40, op: .decrypt, slot: 2)
        #expect(heldUntil(touchWait(&c, commandAt: 40), 40 + TouchTiming.cachedDetectionThreshold))

        var off = HostCoordinator(touchCache: 0)
        learn(&off, [1: .cached])
        touchedOperation(&off)
        start(&off, at: 5)
        #expect(shows(touchWait(&off, commandAt: 5)))
    }

    // MARK: Passive learning

    @Test func uifReportsUpdateOneSlotAndSave() {
        var c = HostCoordinator()
        learn(&c, [1: .cached, 2: .cached, 3: .cached])
        let outputs = c.handle(.touchPolicy(TouchPolicyReport(serial: Self.serial, slot: 3, uif: 1)), from: proxy, now: at(0))
        let expected = CardTouchPolicy(serial: Self.serial, slots: [1: .cached, 2: .cached, 3: .on])
        #expect(outputs == [.saveCardPolicies([expected])])
        #expect(c.policies[Self.display] == expected)
        #expect(c.takeLog().contains(.touchPolicyLearned(serial: Self.display, policies: "sign cached, decrypt cached, auth on")))
        // The same value again changes nothing.
        #expect(c.handle(.touchPolicy(TouchPolicyReport(serial: Self.serial, slot: 3, uif: 1)), from: proxy, now: at(1)).isEmpty)
    }

    @Test func unknownUifValueForgetsTheSlot() {
        var c = HostCoordinator()
        learn(&c, [1: .on])
        for uif in [nil, 5, 0x7F, 300, -1] {
            _ = c.handle(.touchPolicy(TouchPolicyReport(serial: Self.serial, slot: 1, uif: uif)), from: proxy, now: at(0))
            #expect(c.policies[Self.display]?.slots[1] == nil, "\(String(describing: uif))")
            learn(&c, [1: .on])
        }
        #expect(c.handle(.touchPolicy(TouchPolicyReport(serial: Self.serial, slot: 4, uif: 1)), from: proxy, now: at(0)).isEmpty)
        #expect(c.handle(.touchPolicy(TouchPolicyReport(serial: "", slot: 1, uif: 1)), from: proxy, now: at(0)).isEmpty)
    }

    // MARK: Active learning

    func helloWithGnuPG(_ c: inout HostCoordinator) {
        _ = c.handle(.hello(Hello(role: .proxy, pid: 9, build: nil, gnupg: Self.gnupg)), from: proxy, now: at(0))
    }

    func queryTimers(_ outputs: [HostOutput]) -> [String] {
        outputs.compactMap { if case .schedule(HostCoordinator.policyQueryDelay, .queryPolicy(let serial)) = $0 { serial } else { nil } }
    }

    @Test func unknownCardIsQueriedOnceWhenIdle() {
        var c = HostCoordinator()
        helloWithGnuPG(&c)
        start(&c, at: 0)
        #expect(queryTimers(end(&c, at: 0.2)) == [Self.display])
        // A second operation before the timer: no second timer.
        start(&c, at: 1)
        #expect(queryTimers(end(&c, at: 1.2)).isEmpty)
        #expect(c.fire(.queryPolicy(serial: Self.display), now: at(4.2)) == [.queryCardPolicy(serial: Self.serial, Self.gnupg)])
        let learned = c.policyQueried(serial: Self.serial, slots: [1: .on, 2: .on, 3: .off], now: at(4.3))
        #expect(learned == [.saveCardPolicies([CardTouchPolicy(serial: Self.serial, slots: [1: .on, 2: .on, 3: .off])])])
        // Known now: no more queries.
        start(&c, at: 10)
        #expect(queryTimers(end(&c, at: 10.2)).isEmpty)
    }

    @Test func busyCardPostponesTheQuery() {
        var c = HostCoordinator()
        helloWithGnuPG(&c)
        start(&c, at: 0)
        _ = end(&c, at: 0.2)
        start(&c, at: 3)
        #expect(c.fire(.queryPolicy(serial: Self.display), now: at(3.2)).isEmpty)
        #expect(queryTimers(end(&c, at: 3.5)) == [Self.display])
        #expect(c.fire(.queryPolicy(serial: Self.display), now: at(6.5)) == [.queryCardPolicy(serial: Self.serial, Self.gnupg)])
    }

    @Test func failedQueryIsNotRepeatedInTheSameRun() {
        var c = HostCoordinator()
        helloWithGnuPG(&c)
        start(&c, at: 0)
        _ = end(&c, at: 0.2)
        _ = c.fire(.queryPolicy(serial: Self.display), now: at(3.2))
        #expect(c.policyQueried(serial: Self.serial, slots: nil, now: at(3.3)).isEmpty)
        #expect(c.takeLog().contains(.touchPolicyQueryFailed(serial: Self.display)))
        start(&c, at: 100)
        #expect(queryTimers(end(&c, at: 100.2)).isEmpty)
    }

    @Test func noQueryWithoutReasonOrMeans() {
        // No GnuPG context from the proxy.
        var plain = HostCoordinator()
        start(&plain, at: 0)
        #expect(queryTimers(end(&plain, at: 0.2)).isEmpty)
        // Not an OpenPGP card.
        var other = HostCoordinator()
        helloWithGnuPG(&other)
        start(&other, at: 0, serial: "0123456789")
        #expect(queryTimers(end(&other, at: 0.2)).isEmpty)
        // Another maker's OpenPGP card: its standard policies count, so it is asked.
        var maker = HostCoordinator()
        helloWithGnuPG(&maker)
        start(&maker, at: 0, serial: Self.otherSerial)
        #expect(queryTimers(end(&maker, at: 0.2)) == ["87654321"])
        // An explicit touch-cache doesn't use the policy.
        var fixed = HostCoordinator(touchCache: 15)
        helloWithGnuPG(&fixed)
        start(&fixed, at: 0)
        #expect(queryTimers(end(&fixed, at: 0.2)).isEmpty)
        // The proxy's connection closed: its context is gone.
        var closed = HostCoordinator()
        helloWithGnuPG(&closed)
        _ = closed.connectionClosed(proxy, now: at(0))
        start(&closed, at: 1)
        #expect(queryTimers(end(&closed, at: 1.2)).isEmpty)
    }

    /// The card waited for a touch on a slot learned as off, until it timed out: the policy changed.
    @Test func contradictedPolicyIsQueriedAgain() {
        var c = HostCoordinator()
        helloWithGnuPG(&c)
        learn(&c, [1: .off])
        start(&c, at: 0)
        #expect(!shows(touchWait(&c, commandAt: 0)))
        #expect(queryTimers(end(&c, at: 15, result: .timeout)) == [Self.display])
        _ = c.fire(.queryPolicy(serial: Self.display), now: at(18))
        _ = c.policyQueried(serial: Self.serial, slots: [1: .off], now: at(18.1))
        // Again within a minute: no new query.
        start(&c, at: 20)
        _ = touchWait(&c, commandAt: 20)
        #expect(queryTimers(end(&c, at: 35, result: .timeout)).isEmpty)
        // A plain failure on an off slot is no contradiction.
        start(&c, at: 100)
        #expect(queryTimers(end(&c, at: 100.2, result: .error)).isEmpty)
        start(&c, at: 200)
        _ = touchWait(&c, commandAt: 200)
        #expect(queryTimers(end(&c, at: 215, result: .timeout)) == [Self.display])
    }
}

@Suite struct CardPolicyFileTests {
    static let serial = "D2760001240103040006123456780000"

    @Test func roundTrips() {
        let cards = [
            CardTouchPolicy(serial: Self.serial, slots: [1: .cached, 2: .on, 3: .off]),
            CardTouchPolicy(serial: "D2760001240103040006000000010000", slots: [1: .fixed, 3: .cachedFixed]),
        ]
        let text = CardPolicyFile.format(cards)
        #expect(text.contains("\(Self.serial) = cached on off\n"))
        #expect(text.contains("D2760001240103040006000000010000 = fixed unknown cached-fixed\n"))
        #expect(Set(CardPolicyFile.parse(text).map(\.serial)) == Set(cards.map(\.serial)))
        #expect(CardPolicyFile.parse(text).first { $0.serial == Self.serial } == cards[0])
    }

    @Test func toleratesOddLines() {
        let text = """
            # comment
            garbage
            = cached cached cached
            not-hex = on on on
            d2760001240103040006123456780000 =   on   sparkly
            \(Self.serial) = off
            """
        let cards = CardPolicyFile.parse(text)
        // The last line for a card wins, and the serial is upper case.
        #expect(cards == [CardTouchPolicy(serial: Self.serial, slots: [1: .off])])
        #expect(cards.first?.displaySerial == "12345678")
        #expect(cards.first?.isYubico == true)
    }

    @Test func queryOutput() {
        let output = "S SERIALNO \(Self.serial)\nOK\nS UIF-1 %03+\nS UIF-2 %01+\nS UIF-3 %00+\nOK\n"
        #expect(CardPolicyFile.parseQueryOutput(output, serial: Self.serial) == [1: .cached, 2: .on, 3: .off])
        // A card without a button: the GETATTR fails, and nothing is known.
        #expect(CardPolicyFile.parseQueryOutput("S SERIALNO \(Self.serial)\nOK\nERR 100663354 No data <SCD>\n", serial: Self.serial) == [:])
        // Odd values are left out.
        #expect(CardPolicyFile.parseQueryOutput("S SERIALNO \(Self.serial)\nS UIF-1 %09+\nS UIF-2\nS UIF-3 %04+\n", serial: Self.serial) == [3: .cachedFixed])
    }

    /// With several cards, the answer must be about the card asked for.
    @Test func queryOutputForAnotherCardIsRejected() {
        #expect(CardPolicyFile.parseQueryOutput("S SERIALNO D2760001240103040006999999990000\nOK\nS UIF-1 %03+\nOK\n", serial: Self.serial) == nil)
        // SERIALNO --demand failed; GETATTR answered for whatever card was current.
        #expect(CardPolicyFile.parseQueryOutput("ERR 100663404 Card not present <SCD>\nS UIF-1 %03+\nOK\n", serial: Self.serial) == nil)
        #expect(CardPolicyFile.parseQueryOutput("", serial: Self.serial) == nil)
    }

    @Test func storeSavesLoadsAndNoticesChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touchglass-policy-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = CardPolicyStore(path: dir + "/cards.conf")
        #expect(store.load().isEmpty)
        #expect(store.reloadIfChanged() == nil)
        let card = CardTouchPolicy(serial: Self.serial, slots: [1: .on])
        #expect(store.save([card]))
        #expect(store.reloadIfChanged() == nil)
        #expect(CardPolicyStore(path: dir + "/cards.conf").load() == [card])
        // Another writer, such as `touchglass card`.
        try "\(Self.serial) = off off off\n".write(toFile: dir + "/cards.conf", atomically: true, encoding: .utf8)
        #expect(store.reloadIfChanged() == [CardTouchPolicy(serial: Self.serial, slots: [1: .off, 2: .off, 3: .off])])
        #expect(store.reloadIfChanged() == nil)
        try FileManager.default.removeItem(atPath: dir + "/cards.conf")
        #expect(store.reloadIfChanged() == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).isEmpty)
    }

    /// The query runs gpg-connect-agent from the proxy's GnuPG; here a stub that records its arguments.
    @Test func queryRunsGpgConnectAgent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touchglass-query-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stub = dir + "/gpg-connect-agent"
        try """
            #!/bin/sh
            for a in "$@"; do printf '%s\\n' "$a"; done > '\(dir)/args'
            printf 'S SERIALNO \(Self.serial)\\nOK\\nS UIF-1 %%03+\\nS UIF-2 %%03+\\nS UIF-3 %%01+\\nOK\\n'
            """.write(toFile: stub, atomically: true, encoding: .utf8)
        chmod(stub, 0o755)
        let query = GnuPGCardPolicyQuery(homeDirectory: "/Users/nobody")
        #expect(query.query(serial: Self.serial, gnupg: GnuPGContext(home: dir + "/g h", binDir: dir)) == [1: .cached, 2: .cached, 3: .on])
        let args = try String(contentsOfFile: dir + "/args", encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["--no-autostart", "--homedir", dir + "/g h", "scd serialno --demand=\(Self.serial)", "scd getattr UIF", "/bye"])
        // The default home.
        #expect(query.arguments(serial: Self.serial, gnupg: GnuPGContext())[2] == "/Users/nobody/.gnupg")
        // Only a hex serial goes into the command.
        #expect(query.query(serial: "D276 OK", gnupg: GnuPGContext(binDir: dir)) == nil)
    }
}
