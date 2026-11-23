import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// A host that is older than one of its helpers exits when idle, so the next helper starts the installed
/// release.
@Suite struct HostRetireTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let pinentry: ConnectionID = 2

    func hello(_ role: PeerRole, build: String?) -> IPCMessage {
        .hello(Hello(role: role, pid: 99, build: build))
    }

    /// The retire timers in `outputs`; each must have the default delay.
    func retireTimers(_ outputs: [HostOutput]) -> [HostTimer] {
        outputs.compactMap { output in
            guard case .schedule(let delay, let timer) = output, case .retire = timer else { return nil }
            #expect(delay == HostCoordinator.defaultRetireAfterIdle)
            return timer
        }
    }

    /// The one retire timer in `outputs`.
    func retireTimer(_ outputs: [HostOutput]) throws -> HostTimer {
        let timers = retireTimers(outputs)
        #expect(timers.count == 1)
        return try #require(timers.first)
    }

    @Test func newerPinentryRetiresTheHostAfterItCloses() throws {
        var c = HostCoordinator(version: "0.1.0")
        #expect(c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now).isEmpty)
        #expect(c.retiring)

        let timer = try retireTimer(c.connectionClosed(pinentry))
        #expect(c.fire(timer, now: now) == [.exit])
    }

    @Test func sameOlderOrUnknownBuildsKeepTheHost() {
        for build in ["0.1.0", "0.0.9", nil, "HEAD-1a2b3c4"] {
            var c = HostCoordinator(version: "0.1.0")
            _ = c.handle(hello(.pinentry, build: build), from: pinentry, now: now)
            _ = c.handle(hello(.proxy, build: build), from: proxy, now: now)
            #expect(!c.retiring)
            #expect(retireTimers(c.connectionClosed(pinentry)).isEmpty)
        }
        // A host without a version, such as a build outside the app bundle, never retires.
        var c = HostCoordinator()
        _ = c.handle(hello(.pinentry, build: "9.9.9"), from: pinentry, now: now)
        #expect(!c.retiring)
    }

    /// Any process of the user may connect as a proxy, so only a verified helper's release counts.
    @Test func anUnverifiedPeerNeverRetiresTheHost() {
        var c = HostCoordinator(version: "0.1.0")
        c.connectionOpened(proxy, peer: PeerIdentity(pid: 99, verified: false))
        #expect(retireTimers(c.handle(hello(.proxy, build: "0.2.0"), from: proxy, now: now)).isEmpty)
        #expect(!c.retiring)
    }

    /// A newer proxy retires the host at once when nothing else holds it; its own connection doesn't count.
    @Test func newerProxyRetiresAnIdleHost() throws {
        var c = HostCoordinator(version: "0.1.0")
        let timer = try retireTimer(c.handle(hello(.proxy, build: "0.2.0"), from: proxy, now: now))
        #expect(c.fire(timer, now: now) == [.exit])
    }

    @Test func runningOperationKeepsTheHostUntilItEnds() throws {
        var c = HostCoordinator(version: "0.1.0")
        _ = c.handle(.opStart(OpStart(conn: "100:p", op: .sign, slot: 1, at: now.timeIntervalSince1970)), from: proxy, now: now)
        _ = c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: now.timeIntervalSince1970)), from: proxy, now: now)
        #expect(retireTimers(c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now)).isEmpty)
        #expect(retireTimers(c.connectionClosed(pinentry)).isEmpty)

        // The success state may still show; the delay outlasts it.
        let ended = c.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        #expect(ended.contains(.panel(.show(.success(.sign)))))
        let timer = try retireTimer(ended)
        #expect(c.fire(timer, now: now) == [.exit])
    }

    /// A timer from before the host was busy again does nothing, so the result that the panel shows now
    /// gets the full delay.
    @Test func timerFromAnEarlierIdleSpellDoesNothing() throws {
        var c = HostCoordinator(version: "0.1.0")
        let early = try retireTimer(c.handle(hello(.proxy, build: "0.2.0"), from: proxy, now: now))
        _ = c.handle(.opStart(OpStart(conn: "100:p", op: .sign, slot: 1, at: now.timeIntervalSince1970)), from: proxy, now: now)
        let ended = c.handle(.opEnd(OpEnd(conn: "100:p", result: .badPin)), from: proxy, now: now)
        let late = try retireTimer(ended)
        #expect(late != early)

        #expect(c.fire(early, now: now).isEmpty)
        #expect(c.fire(late, now: now) == [.exit])
    }

    /// A pinentry that connects while the host waits to exit keeps it; the host exits after that one closes.
    @Test func pinentryThatConnectsMeanwhileKeepsTheHost() throws {
        var c = HostCoordinator(version: "0.1.0")
        _ = c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now)
        let early = try retireTimer(c.connectionClosed(pinentry))

        _ = c.handle(hello(.pinentry, build: "0.2.0"), from: 3, now: now)
        #expect(c.fire(early, now: now).isEmpty)
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Passphrase")), from: 3, now: now)
        #expect(retireTimers(c.handle(.submit("x"))).isEmpty)

        let timer = try retireTimer(c.connectionClosed(3))
        #expect(c.fire(timer, now: now) == [.exit])
    }
}
