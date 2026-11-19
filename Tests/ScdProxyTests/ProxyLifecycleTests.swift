import Darwin
import Foundation
import ScdProxyCore
import ScdTestSupport
import Synchronization
import Testing
import TouchGlassIPC

/// The proxy keeps the host informed when scdaemon, the host or a signal interrupts it.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProxyLifecycleTests {
    static let sign = ProxyHarness.signGrip

    func isTouchWait(_ message: IPCMessage) -> Bool {
        if case .touchWait = message { true } else { false }
    }

    /// The relay thread of a socket session may not run before the proxy exits; the proxy ends the
    /// session's operation itself.
    @Test func scdaemonKilledDuringASocketOperationEndsIt() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 5000
        let harness = try ProxyHarness(card: card)
        defer { harness.cleanUp() }
        let host = try FakeHost(path: harness.hostSocketPath)
        defer { host.close() }
        try harness.start()
        let socket = try #require(harness.handshake())
        let session = try #require(harness.openSocketSession(path: socket))
        session.send(Array("PKSIGN --hash=sha256 \(Self.sign)\n".utf8))
        host.waitFor(isTouchWait)

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-P", String(harness.process.processIdentifier)]
        try pkill.run()
        pkill.waitUntilExit()

        let exit = harness.waitForExit(timeout: 5)
        #expect(exit?.reason == .uncaughtSignal)
        let summaries = host.waitFor { $0.summary == "op_end s1 error" }.map(\.summary)
        #expect(summaries == ["op_start s1 sign slot=-", "touch_wait s1", "op_end s1 error"])
    }

    /// The first write after a host restart fails; the sink reconnects and sends that event again.
    @Test func hostRestartKeepsTheFirstEvent() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        let harness = try ProxyHarness(card: card)
        defer { harness.cleanUp() }
        var first: FakeHost? = try FakeHost(path: harness.hostSocketPath)
        try harness.start()
        _ = harness.handshake()
        #expect(harness.agent.transact("PKSIGN --hash=sha256 \(Self.sign)").isOK)
        #expect(first?.waitForMessages(count: 2).map(\.summary) == ["op_start p sign slot=-", "op_end p ok"])

        // Stop the first host, including the accepted connection, and start a second one.
        first?.close()
        first?.dropConnections()
        first = nil
        let second = try FakeHost(path: harness.hostSocketPath)
        defer { second.close() }

        #expect(harness.agent.transact("PKSIGN --hash=sha256 \(Self.sign)").isOK)
        #expect(second.waitForMessages(count: 2).map(\.summary) == ["op_start p sign slot=-", "op_end p ok"])
        #expect(harness.finish()?.status == 0)
    }

    /// scdaemon sends its event signal to the peer of a socket session, which is the proxy.
    @Test(arguments: [SIGUSR1, SIGUSR2])
    func eventSignalsDoNotEndTheProxy(signal: Int32) throws {
        let harness = try ProxyHarness(card: .init())
        defer { harness.cleanUp() }
        try harness.start()
        _ = harness.handshake()
        kill(harness.process.processIdentifier, signal)
        #expect(harness.waitForExit(timeout: 0.5) == nil)
        #expect(harness.agent.transact("SERIALNO").isOK)
        #expect(harness.finish()?.status == 0)
    }

    /// scdaemon starts with the dispositions it has under gpg-agent: the signals that the proxy handles or
    /// ignores at their defaults, whatever the proxy inherited, and `SIGPIPE` as the proxy inherited it.
    @Test(arguments: [[], ["PIPE", "USR1", "USR2", "TERM"]])
    func scdaemonStartsWithTheAgentsSignalDispositions(ignoredSignals: [String]) throws {
        let harness = try ProxyHarness(card: .init(), ignoredSignals: ignoredSignals)
        defer { harness.cleanUp() }
        try harness.start()
        #expect(harness.finish()?.status == 0)
        let record = harness.scdaemonStartRecord.components(separatedBy: "\nSIGNALS\n")
        let pipe = ignoredSignals.contains("PIPE") ? "ignore" : "default"
        #expect(record.last == "HUP=default\nINT=default\nPIPE=\(pipe)\nTERM=default\nUSR1=default\nUSR2=default\n")
    }

    @Test func hostAppSetting() throws {
        let base = [ProxyConfig.scdaemonEnvironmentKey: "/usr/bin/true"]
        #expect(try #require(ProxyConfig.resolve(environment: base.merging(["TOUCHGLASS_HOST_APP": "none"]) { $1 })).hostApp == nil)
        #expect(try #require(ProxyConfig.resolve(environment: base.merging(["TOUCHGLASS_HOST_APP": "/Applications/TouchGlass.app"]) { $1 })).hostApp == "/Applications/TouchGlass.app")
        #expect(try #require(ProxyConfig.resolve(environment: base)).hostApp != nil)
    }
}

/// The sink starts the host on `op_start` when it can't connect.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HostEventSinkLaunchTests {
    func socketPath() -> (directory: String, socket: String) {
        let directory = "/tmp/tgs-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        return (directory, directory + "/host/host.sock")
    }

    func opStart(_ conn: String) -> IPCMessage {
        .opStart(OpStart(conn: conn, op: .sign, slot: 1, serial: nil, at: Date().timeIntervalSince1970))
    }

    @Test func opStartLaunchesTheHostAndBothEventsArrive() throws {
        let (directory, socket) = socketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let launches = Atomic<Int>(0)
        let started = Mutex<FakeHost?>(nil)
        let sink = HostEventSink(path: socket) {
            launches.add(1, ordering: .relaxed)
            // The app takes a moment to start listening.
            Thread.detachNewThread {
                usleep(300_000)
                let host = try? FakeHost(path: socket)
                started.withLock { $0 = host }
            }
            return true
        }
        sink.send(opStart("1:p"))
        sink.send(.touchWait(TouchWait(conn: "1:p", at: Date().timeIntervalSince1970)))
        sink.flush(timeout: 5)

        let host = try #require(started.withLock { $0 })
        defer { host.close() }
        #expect(host.waitForMessages(count: 2).map(\.summary) == ["op_start p sign slot=1", "touch_wait p"])
        #expect(launches.load(ordering: .relaxed) == 1)
    }

    @Test func launchesAreRateLimitedAndOnlyForOpStart() throws {
        let (directory, socket) = socketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let launches = Atomic<Int>(0)
        let sink = HostEventSink(path: socket) {
            launches.add(1, ordering: .relaxed)
            return false
        }
        sink.send(.pinNeeded(ConnRef(conn: "1:p")))
        sink.flush(timeout: 2)
        #expect(launches.load(ordering: .relaxed) == 0)

        sink.send(opStart("1:p"))
        sink.send(opStart("1:s1"))
        sink.flush(timeout: 2)
        #expect(launches.load(ordering: .relaxed) == 1)
    }
}
