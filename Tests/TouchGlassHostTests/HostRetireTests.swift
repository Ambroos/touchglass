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

    func retireTimers(_ outputs: [HostOutput]) -> [TimeInterval] {
        outputs.compactMap { if case .schedule(let delay, .retire) = $0 { delay } else { nil } }
    }

    @Test func newerPinentryRetiresTheHostAfterItCloses() {
        var c = HostCoordinator(version: "0.1.0")
        #expect(c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now).isEmpty)
        #expect(c.retiring)

        let closed = c.connectionClosed(pinentry)
        #expect(retireTimers(closed) == [HostCoordinator.defaultRetireAfterIdle])
        #expect(c.fire(.retire, now: now) == [.exit])
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

    /// A newer proxy retires the host at once when nothing else holds it; its own connection doesn't count.
    @Test func newerProxyRetiresAnIdleHost() {
        var c = HostCoordinator(version: "0.1.0")
        #expect(retireTimers(c.handle(hello(.proxy, build: "0.2.0"), from: proxy, now: now)) == [HostCoordinator.defaultRetireAfterIdle])
        #expect(c.fire(.retire, now: now) == [.exit])
    }

    @Test func runningOperationKeepsTheHostUntilItEnds() {
        var c = HostCoordinator(version: "0.1.0")
        _ = c.handle(.opStart(OpStart(conn: "100:p", op: .sign, slot: 1, at: now.timeIntervalSince1970)), from: proxy, now: now)
        _ = c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", at: now.timeIntervalSince1970)), from: proxy, now: now)
        #expect(retireTimers(c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now)).isEmpty)
        #expect(retireTimers(c.connectionClosed(pinentry)).isEmpty)

        // The success state may still show; the delay outlasts it.
        let ended = c.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        #expect(ended.contains(.panel(.show(.success(.sign)))))
        #expect(retireTimers(ended) == [HostCoordinator.defaultRetireAfterIdle])
        #expect(c.fire(.retire, now: now) == [.exit])
    }

    /// A pinentry that connects while the host waits to exit keeps it; the host exits after that one closes.
    @Test func pinentryThatConnectsMeanwhileKeepsTheHost() {
        var c = HostCoordinator(version: "0.1.0")
        _ = c.handle(hello(.pinentry, build: "0.2.0"), from: pinentry, now: now)
        #expect(retireTimers(c.connectionClosed(pinentry)).count == 1)

        _ = c.handle(hello(.pinentry, build: "0.2.0"), from: 3, now: now)
        #expect(c.fire(.retire, now: now).isEmpty)
        _ = c.handle(.getPin(GetPin(id: "r1", desc: "Passphrase")), from: 3, now: now)
        #expect(retireTimers(c.handle(.submit("x"))).isEmpty)

        let closed = c.connectionClosed(3)
        #expect(retireTimers(closed) == [HostCoordinator.defaultRetireAfterIdle])
        #expect(c.fire(.retire, now: now) == [.exit])
    }
}
