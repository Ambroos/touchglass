import Darwin
import Foundation
import ScdTestSupport
import Testing
import TouchGlassIPC

/// End-to-end tests: the test acts as gpg-agent, touchglass-scdaemon runs fake-scdaemon, and a fake host
/// collects the events. Nothing here touches a real card, gpg-agent or ~/.gnupg.
@Suite(.timeLimit(.minutes(1)))
struct ProxyIntegrationTests {
    static let sign = ProxyHarness.signGrip
    static let decrypt = ProxyHarness.decryptGrip
    static let auth = ProxyHarness.authGrip

    /// Starts a harness with a fake host, runs the handshake and returns all three.
    func setUp(card: ProxyHarness.Card = .init(), withSocket: Bool = true, host: Bool = true, extraEnvironment: [String: String] = [:]) throws -> (ProxyHarness, FakeHost?, String?) {
        let harness = try ProxyHarness(card: card, withSocket: withSocket, extraEnvironment: extraEnvironment)
        var fakeHost: FakeHost?
        if host { fakeHost = try FakeHost(path: harness.hostSocketPath) }
        let hello = try harness.start()
        #expect(hello?.hasPrefix("OK GNU Privacy Guard's Smartcard server ready") == true)
        let socket = harness.handshake()
        return (harness, fakeHost, socket)
    }

    /// Sends the agent's command sequence for one card operation and returns the final reply.
    @discardableResult
    func operation(_ agent: AgentDriver, _ command: String, grip: String, pin: String? = "123456", cachedPin: String? = nil) -> AgentDriver.Reply {
        _ = agent.transact("SERIALNO --all")
        _ = agent.transact("KEYINFO \(grip)")
        _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
        let pk = command == "PKSIGN" ? "PKSIGN --hash=sha512 \(grip)" : "\(command) \(grip)"
        return agent.transact(pk, inquiries: AgentDriver.standardInquiries(pin: pin, cachedPin: cachedPin))
    }

    func summaries(_ host: FakeHost?, waitingFor count: Int) -> [String] {
        host?.waitForMessages(count: count).map(\.summary) ?? []
    }

    // MARK: - Byte transparency

    /// Replaces the first `D <real socket>` line in scdaemon's output with the proxy's path: the one change
    /// the proxy makes on purpose.
    func expectedClientBytes(_ scdOut: [UInt8], real: String, proxy: String?) -> [UInt8] {
        guard let proxy else { return scdOut }
        let needle = Array("D \(real)\n".utf8)
        guard let range = scdOut.firstRange(of: needle) else { return scdOut }
        var out = scdOut
        out.replaceSubrange(range, with: Array("D \(proxy)\n".utf8))
        return out
    }

    /// Traffic with every awkward byte: NUL, CR, raw high bytes, %-escapes, long and empty lines, binary D lines.
    func awkwardTraffic(_ agent: AgentDriver) {
        let allBytes = (0...255).map { UInt8($0) }
        #expect(agent.transact("BLOB").isOK)
        let echo = agent.transact("ECHOINQ", inquiries: { _, _ in allBytes + allBytes.reversed() + [UInt8](repeating: 0x25, count: 1200) })
        #expect(echo.isOK)
        #expect(echo.dataPayload == allBytes + allBytes.reversed() + [UInt8](repeating: 0x25, count: 1200))
        // Unknown commands carrying raw bytes, an over-long line and a CRLF line: forwarded untouched, answered by scdaemon.
        _ = agent.transact(raw: Array("NOP \0\u{1}".utf8) + [0xFF, 0xFE, 0x80] + Array(" %0A%25 +\n".utf8))
        _ = agent.transact(raw: Array("XLONG ".utf8) + [UInt8](repeating: 0xE9, count: 1500) + [0x0A])
        _ = agent.transact(raw: Array("SERIALNO\r\n".utf8))
        _ = agent.transact(raw: Array("\n\nNOP\n".utf8))
        operation(agent, "PKSIGN", grip: Self.sign)
    }

    @Test func pipeIsByteTransparentInBothDirections() throws {
        var card = ProxyHarness.Card()
        card.split_writes = true
        let (harness, host, socket) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        harness.agent.splitWrites = true
        awkwardTraffic(harness.agent)
        #expect(harness.finish()?.status == 0)

        #expect(socket != harness.realSocketPath)
        #expect(socket?.hasPrefix(harness.runtimeDirectory) == true)
        #expect(harness.agent.sent == harness.recorded("pipe", "in"))
        #expect(harness.agent.received == expectedClientBytes(harness.recorded("pipe", "out"), real: harness.realSocketPath, proxy: socket))
    }

    @Test func socketSessionIsByteTransparentInBothDirections() throws {
        var card = ProxyHarness.Card()
        card.split_writes = true
        let (harness, host, socket) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        let path = try #require(socket)
        let session = try #require(harness.openSocketSession(path: path))
        session.splitWrites = true
        awkwardTraffic(session)
        // The agent asks for the socket name on a socket session too; it must get the proxy's path again.
        let again = session.transact("GETINFO socket_name")
        #expect(String(decoding: again.dataPayload, as: UTF8.self) == path)
        _ = session.transact("BYE")
        _ = session.readToEnd()
        close(session.input)

        #expect(session.sent == harness.recorded("sock1", "in"))
        #expect(session.received == expectedClientBytes(harness.recorded("sock1", "out"), real: harness.realSocketPath, proxy: path))
        #expect(harness.finish()?.status == 0)
    }

    @Test func emptySocketNamePassesThroughUnchanged() throws {
        let (harness, host, socket) = try setUp(withSocket: false)
        defer { harness.cleanUp(); host?.close() }
        #expect(socket == nil)
        #expect(harness.finish()?.status == 0)
        #expect(harness.agent.received == harness.recorded("pipe", "out"))
    }

    // MARK: - Event sequences

    @Test func signWithPinAndTouch() throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        let reply = operation(harness.agent, "PKSIGN", grip: Self.sign)
        #expect(reply.isOK)
        #expect(summaries(host, waitingFor: 5) == ["op_start p sign slot=1", "pin_needed p", "pin_sent p", "touch_wait p", "op_end p ok"])
        if case let .opStart(start) = host?.messages.first {
            #expect(start.serial == ProxyHarness.serial)
        }
        if case let .touchWait(wait) = host?.messages[3] {
            #expect(wait.timeoutMs == 15_000)
            #expect(wait.at != nil)
        }
        #expect(harness.finish()?.status == 0)
    }

    @Test func signWithCachedPin() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign).isOK)
        #expect(summaries(host, waitingFor: 3) == ["op_start p sign slot=1", "touch_wait p", "op_end p ok"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func pinFromAgentCacheShowsNoPinStep() throws {
        var card = ProxyHarness.Card()
        card.pincache = true
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign, cachedPin: "CAFEF00D").isOK)
        #expect(summaries(host, waitingFor: 3) == ["op_start p sign slot=1", "touch_wait p", "op_end p ok"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func cachedTouchSendsNoTouchWait() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 700
        card.touch_cache_ms = 15_000
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign).isOK)
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign).isOK)
        usleep(300_000)
        #expect(summaries(host, waitingFor: 5) == [
            "op_start p sign slot=1", "touch_wait p", "op_end p ok",
            "op_start p sign slot=1", "op_end p ok",
        ])
        #expect(harness.finish()?.status == 0)
    }

    @Test func sshAuthentication() throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        _ = harness.agent.transact("KEYINFO --list=auth")
        #expect(operation(harness.agent, "PKAUTH", grip: Self.auth).isOK)
        // gpg-agent may also sign with the authentication key; scdaemon runs it as INTERNAL AUTHENTICATE.
        #expect(operation(harness.agent, "PKSIGN", grip: Self.auth).isOK)
        #expect(summaries(host, waitingFor: 8) == [
            "op_start p auth slot=3", "pin_needed p", "pin_sent p", "touch_wait p", "op_end p ok",
            "op_start p auth slot=3", "touch_wait p", "op_end p ok",
        ])
        #expect(harness.finish()?.status == 0)
    }

    @Test func decrypt() throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        let reply = operation(harness.agent, "PKDECRYPT", grip: Self.decrypt)
        #expect(reply.isOK)
        #expect(reply.statusLines.contains("S PADDING 0"))
        #expect(summaries(host, waitingFor: 5) == ["op_start p decrypt slot=2", "pin_needed p", "pin_sent p", "touch_wait p", "op_end p ok"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func badPin() throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 700
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        let reply = operation(harness.agent, "PKSIGN", grip: Self.sign, pin: "000000")
        #expect(reply.final == "ERR 100663383 Bad PIN <SCD>")
        #expect(summaries(host, waitingFor: 4) == ["op_start p sign slot=1", "pin_needed p", "pin_sent p", "op_end p bad_pin"])
        if case let .opEnd(end) = host?.messages.last { #expect(end.code == 100663383) }
        #expect(harness.finish()?.status == 0)
    }

    @Test func touchTimeout() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 700
        card.touch_timeout = true
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign).final == "ERR 100663358 Timeout <SCD>")
        #expect(summaries(host, waitingFor: 3) == ["op_start p sign slot=1", "touch_wait p", "op_end p timeout"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func cancelledPinEntry() throws {
        let (harness, host, _) = try setUp()
        defer { harness.cleanUp(); host?.close() }
        let reply = operation(harness.agent, "PKSIGN", grip: Self.sign, pin: nil)
        #expect(reply.final == "ERR 100663573 IPC call has been cancelled <SCD>")
        #expect(summaries(host, waitingFor: 3) == ["op_start p sign slot=1", "pin_needed p", "op_end p cancelled"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func overlappingSocketSession() throws {
        var card = ProxyHarness.Card()
        card.verified = [1, 2]
        card.touch_ms = 800
        let (harness, host, socket) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        let path = try #require(socket)
        let session = try #require(harness.openSocketSession(path: path))

        let agent = harness.agent
        let pipeDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = self.operation(agent, "PKSIGN", grip: Self.sign)
            pipeDone.signal()
        }
        usleep(100_000)
        #expect(operation(session, "PKAUTH", grip: Self.auth).isOK)
        pipeDone.wait()
        _ = session.transact("BYE")
        close(session.input)

        let messages = try #require(host).waitForMessages(count: 6)
        let byConn = Dictionary(grouping: messages.map(\.summary)) { $0.split(separator: " ")[1] }
        #expect(byConn["p"] == ["op_start p sign slot=1", "touch_wait p", "op_end p ok"])
        #expect(byConn["s1"] == ["op_start s1 auth slot=3", "touch_wait s1", "op_end s1 ok"])
        #expect(harness.finish()?.status == 0)
    }

    @Test func eventsNeverCarryThePin() throws {
        var card = ProxyHarness.Card()
        card.pin = "987654"
        card.touch_ms = 500
        final class Bytes: @unchecked Sendable { var value: [UInt8] = [] }
        let raw = Bytes()
        let lock = NSLock()
        let harness = try ProxyHarness(card: card)
        let host = try FakeHost(path: harness.hostSocketPath) { message in
            let line = (try? IPCLine.encode(message)) ?? Data()
            lock.lock(); raw.value += line; lock.unlock()
        }
        defer { harness.cleanUp(); host.close() }
        try harness.start()
        _ = harness.handshake()
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign, pin: "987654").isOK)
        operation(harness.agent, "PKAUTH", grip: Self.auth, pin: "987650")
        host.waitForMessages(count: 9)
        lock.lock(); let all = raw.value; lock.unlock()
        #expect(!all.isEmpty)
        #expect(all.firstRange(of: Array("98765".utf8)) == nil)
        #expect(!String(decoding: all, as: UTF8.self).contains("Please unlock"))
        #expect(harness.finish()?.status == 0)
    }

    // MARK: - Host absent or stalled

    @Test func worksWithoutHost() throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 500
        let (harness, _, _) = try setUp(card: card, host: false)
        defer { harness.cleanUp() }
        let start = Date()
        #expect(operation(harness.agent, "PKSIGN", grip: Self.sign).isOK)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(harness.finish()?.status == 0)
    }

    @Test func stoppedHostDoesNotSlowForwarding() throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        let harness = try ProxyHarness(card: card)
        defer { harness.cleanUp() }
        try FileManager.default.createDirectory(atPath: (harness.hostSocketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hostProcess = Process()
        hostProcess.executableURL = URL(fileURLWithPath: ProxyHarness.executable("fake-host"))
        hostProcess.arguments = ["--socket", harness.hostSocketPath]
        hostProcess.standardOutput = FileHandle.nullDevice
        hostProcess.standardError = FileHandle.nullDevice
        try hostProcess.run()
        defer {
            kill(hostProcess.processIdentifier, SIGCONT)
            hostProcess.terminate()
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while access(harness.hostSocketPath, F_OK) != 0 && Date() < deadline { usleep(10_000) }
        kill(hostProcess.processIdentifier, SIGSTOP)

        try harness.start()
        _ = harness.handshake()
        // Each operation sends two events; 400 operations fill the stopped host's socket buffer many times over.
        let start = Date()
        for _ in 0..<400 {
            #expect(harness.agent.transact("PKSIGN --hash=sha256 \(Self.sign)").isOK)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5, "400 operations took \(elapsed) s with a stopped host")
        #expect(harness.finish()?.status == 0)
    }

    // MARK: - Process behaviour

    @Test func exitStatusFollowsScdaemon() throws {
        let (harness, host, _) = try setUp()
        defer { harness.cleanUp(); host?.close() }
        harness.agent.send(Array("EXIT 7\n".utf8))
        let result = harness.waitForExit()
        #expect(result?.status == 7)
        #expect(result?.reason == .exit)
    }

    @Test func killscdEndsProxy() throws {
        let (harness, host, _) = try setUp()
        defer { harness.cleanUp(); host?.close() }
        #expect(harness.agent.transact("KILLSCD").final == "OK closing connection")
        #expect(harness.waitForExit()?.status == 0)
    }

    @Test func agentEndOfFileKeepsForwardingUntilScdaemonExits() throws {
        var card = ProxyHarness.Card()
        card.exit_on_eof = 3
        card.eof_linger_ms = 300
        let (harness, host, _) = try setUp(card: card)
        defer { harness.cleanUp(); host?.close() }
        harness.agent.closeOutput()
        #expect(harness.agent.readLine().map { String(decoding: $0, as: UTF8.self) } == "# stdin closed, exiting")
        let result = harness.waitForExit()
        #expect(result?.status == 3)
        #expect(result?.reason == .exit)
        // The relay socket is removed on exit.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.runtimeDirectory)) == [])
    }

    @Test func signalsReachScdaemonAndTheProxyDiesTheSameWay() throws {
        let (harness, host, _) = try setUp()
        defer { harness.cleanUp(); host?.close() }
        kill(harness.process.processIdentifier, SIGTERM)
        let result = harness.waitForExit()
        #expect(result?.reason == .uncaughtSignal)
        #expect(result?.status == SIGTERM)
    }

    @Test func argumentsAndEnvironmentReachScdaemonUnchanged() throws {
        let (harness, host, _) = try setUp(extraEnvironment: ["TOUCHGLASS_TEST_MARKER": "a b%c"])
        defer { harness.cleanUp(); host?.close() }
        #expect(harness.finish()?.status == 0)
        let record = harness.scdaemonStartRecord
        let args = record.components(separatedBy: "\nENV\n")[0].split(separator: "\n").dropFirst()
        #expect(Array(args) == ["fake-scdaemon", "--multi-server"])
        #expect(record.contains("\nTOUCHGLASS_TEST_MARKER=a b%c\n"))
        #expect(record.contains("\n_assuan_pipe_connect_pid=\(getpid())\n"))
    }
}
