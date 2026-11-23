import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// Only a verified helper may ask for a prompt; any other process of the user may still act as a proxy.
@Suite struct HostPeerCheckTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let stranger: ConnectionID = 2
    let cardDescription = "Please unlock the card\n\nNumber: 12 345 678\nHolder: \nCounter: 7"

    func opened(verified: Bool, as connection: ConnectionID) -> HostCoordinator {
        var c = HostCoordinator()
        c.connectionOpened(connection, peer: PeerIdentity(pid: 4100, verified: verified))
        return c
    }

    @Test(arguments: [
        IPCMessage.hello(Hello(role: .pinentry, pid: 4100)),
        .getPin(GetPin(id: "r1", desc: "Please enter the passphrase")),
        .confirm(Confirm(id: "r1", desc: "Trust this key?")),
        .message(MessageRequest(id: "r1", desc: "Done")),
        .dismiss(RequestRef(id: "r1")),
    ])
    func anUnverifiedPeerThatAsksForAPromptIsClosed(message: IPCMessage) {
        var c = opened(verified: false, as: stranger)
        #expect(c.handle(message, from: stranger, now: now) == [.close(stranger)])
        #expect(c.takeLog() == [.connectionRefused(id: stranger, pid: 4100, notLogged: 0)])
        // Whatever it sends before the close lands changes nothing.
        #expect(c.handle(.getPin(GetPin(id: "r2", desc: cardDescription)), from: stranger, now: now).isEmpty)
        #expect(c.takeLog().isEmpty)
    }

    @Test func aVerifiedPinentryGetsItsPrompt() {
        var c = opened(verified: true, as: stranger)
        _ = c.handle(.hello(Hello(role: .pinentry, pid: 4100)), from: stranger, now: now)
        let outputs = c.handle(.getPin(GetPin(id: "r1", desc: "Please enter the passphrase")), from: stranger, now: now)
        #expect(outputs.contains { if case .panel(.show(.passphrase)) = $0 { true } else { false } })
    }

    /// The proxy of an earlier release keeps running after `brew upgrade`, with code that no longer
    /// matches a helper on disk. Its touch panels still show.
    @Test func anUnverifiedProxyStillShowsTheTouch() {
        var c = opened(verified: false, as: proxy)
        #expect(c.handle(.hello(Hello(role: .proxy, pid: 4100, build: "0.1.2")), from: proxy, now: now).isEmpty)
        _ = c.handle(.opStart(OpStart(conn: "100:p", op: .sign, slot: 1, serial: "D2760001240103040006123456780000", at: now.timeIntervalSince1970)), from: proxy, now: now)
        let outputs = c.handle(.touchWait(TouchGlassIPC.TouchWait(conn: "100:p", timeoutMs: 15_000, at: now.timeIntervalSince1970)), from: proxy, now: now.addingTimeInterval(0.4))
        #expect(outputs.contains { if case .panel(.show(.touchWait)) = $0 { true } else { false } })
        #expect(!outputs.contains { if case .close = $0 { true } else { false } })
    }

    @Test func refusalsReachTheLogAtMostOncePerSecond() {
        var c = HostCoordinator()
        let hello = IPCMessage.hello(Hello(role: .pinentry, pid: 1))
        for id in 10..<14 {
            c.connectionOpened(id, peer: PeerIdentity(pid: Int32(id), verified: false))
        }
        _ = c.handle(hello, from: 10, now: now)
        _ = c.handle(hello, from: 11, now: now.addingTimeInterval(0.3))
        _ = c.handle(hello, from: 12, now: now.addingTimeInterval(0.6))
        _ = c.handle(hello, from: 13, now: now.addingTimeInterval(1.2))
        #expect(c.takeLog() == [
            .connectionRefused(id: 10, pid: 10, notLogged: 0),
            .connectionRefused(id: 13, pid: 13, notLogged: 2),
        ])
        #expect(LogEvent.connectionRefused(id: 13, pid: 13, notLogged: 2).message.hasSuffix("(2 more refused since the last such line)"))
    }
}
