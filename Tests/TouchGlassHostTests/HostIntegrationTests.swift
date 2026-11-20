import Darwin
import Foundation
import ScdTestSupport
import Synchronization
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// Records panel events instead of showing a window, and can answer PIN prompts.
@MainActor
final class RecordingPanel: PanelDriving {
    var events: [PanelEvent] = []
    var actions = PanelActions()
    /// Submitted automatically when a PIN or passphrase prompt shows. A fake test value.
    var autoSubmit: String?

    func send(_ event: PanelEvent) {
        events.append(event)
        switch event {
        case .show(.pinEntry), .show(.passphrase):
            if let autoSubmit {
                DispatchQueue.main.async { self.actions.submitSecret(autoSubmit) }
            }
        default:
            break
        }
    }

    func shakeField() {}

    func setActions(_ actions: PanelActions) {
        self.actions = actions
    }

    func contains(_ match: (PanelEvent) -> Bool) -> Bool {
        events.contains(where: match)
    }
}

/// Waits on the suspending clock, which stops while the Mac sleeps, like the host's dispatch timers: a
/// deadline on the wall clock would pass during sleep while the timer it waits for doesn't.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A short socket directory: Unix socket paths hold at most 103 bytes.
func shortSocketPath() -> (directory: String, socket: String) {
    let directory = "/tmp/tgh-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    return (directory, directory + "/sock/host.sock")
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct HostIntegrationTests {
    /// The proxy runs over fake-scdaemon; the test plays gpg-agent and answers the PIN inquiry itself.
    @Test func proxyEventsDriveTouchAndSuccess() async throws {
        var card = ProxyHarness.Card()
        card.touch_ms = 900
        let harness = try ProxyHarness(card: card)
        defer { harness.cleanUp() }
        let server = try HostServer(path: harness.hostSocketPath)
        let panel = RecordingPanel()
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        let agent = harness.agent
        let grip = ProxyHarness.signGrip
        let operation = Task.detached {
            _ = agent.transact("SERIALNO --all")
            _ = agent.transact("KEYINFO \(grip)")
            _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
            return agent.transact("PKSIGN --hash=sha512 \(grip)", inquiries: AgentDriver.standardInquiries(pin: "123456")).isOK
        }

        #expect(await waitUntil { panel.contains { if case .show(.touchWait(let wait)) = $0 { wait.operation == .sign } else { false } } })
        #expect(await operation.value)
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })
        #expect(harness.finish()?.status == 0)
    }

    /// A signature that needs the PIN and a touch, with every real component: the proxy over fake-scdaemon
    /// reports the operation on one host connection, the real pinentry asks for the PIN on another, and the
    /// panel goes from PIN entry to verifying to touch to success. The test plays gpg-agent: it answers
    /// NEEDPIN by running the pinentry, as the agent does.
    @Test func pinThenTouchSignatureAcrossProxyAndPinentry() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var card = ProxyHarness.Card()
        card.touch_ms = 900
        let harness = try ProxyHarness(card: card, hostPath: socket)
        defer { harness.cleanUp() }
        let server = try HostServer(path: socket)
        let panel = RecordingPanel()
        // A fake test PIN, the fake card's default.
        panel.autoSubmit = "123456"
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        let agent = harness.agent
        let grip = ProxyHarness.signGrip
        let operation = Task.detached { () -> (signed: Bool, pinentry: [String]) in
            _ = agent.transact("SERIALNO --all")
            _ = agent.transact("KEYINFO \(grip)")
            _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
            let transcript = Mutex<[String]>([])
            let reply = agent.transact("PKSIGN --hash=sha512 \(grip)") { keyword, _ in
                switch keyword {
                case "PINCACHE_GET":
                    return []
                case "NEEDPIN":
                    // gpg-agent starts the pinentry only when scdaemon asks for the PIN.
                    guard let pinentry = try? PinentryProcess(socket: socket, home: directory) else { return nil }
                    defer { pinentry.stop() }
                    var lines: [String] = []
                    func exchange(_ command: String) {
                        pinentry.send(command)
                        while let line = pinentry.readLineBlocking() {
                            lines.append(line)
                            if line.hasPrefix("OK") || line.hasPrefix("ERR") { break }
                        }
                    }
                    lines += pinentry.readLineBlocking().map { [$0] } ?? []
                    exchange("SETDESC Please unlock the card%0A%0A\u{1E}Number\u{1F}: 12 345 678%0AHolder\u{1F}: %0ACounter\u{1F}: 7")
                    exchange("SETPROMPT PIN")
                    exchange("GETPIN")
                    exchange("BYE")
                    transcript.withLock { $0 = lines }
                    let pin = lines.first { $0.hasPrefix("D ") }.map { String($0.dropFirst(2)) }
                    return pin.map(AgentDriver.pinAnswer)
                default:
                    return nil
                }
            }
            return (reply.isOK, transcript.withLock { $0 })
        }

        let result = await operation.value
        #expect(result.signed)
        #expect(result.pinentry.contains("D 123456"))
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })

        // The prompt ID is the pinentry's request ID, which the test doesn't know.
        let request = PinRequest(operation: .sign, cardSerial: "12345678")
        let pinIndex = panel.events.firstIndex { if case .show(.pinEntry(var shown)) = $0 { shown.promptID = nil; return shown == request } else { return false } }
        let verifyingIndex = panel.events.firstIndex { if case .show(.verifying(var shown)) = $0 { shown.promptID = nil; return shown == request } else { return false } }
        let touchIndex = panel.events.firstIndex { if case .show(.touchWait(let wait)) = $0 { wait.operation == .sign } else { false } }
        let successIndex = panel.events.firstIndex(of: .show(.success(.sign)))
        #expect(pinIndex != nil && verifyingIndex != nil && touchIndex != nil && successIndex != nil, "events: \(panel.events)")
        if let pinIndex, let verifyingIndex, let touchIndex, let successIndex {
            #expect(pinIndex < verifyingIndex && verifyingIndex < touchIndex && touchIndex < successIndex)
        }
        // The verifying state stays until the card reports back; the pinentry closing does not dismiss it.
        if let verifyingIndex, let touchIndex {
            #expect(!panel.events[verifyingIndex..<touchIndex].contains(.dismiss))
        }
        #expect(harness.finish()?.status == 0)
    }

    /// A pinentry of a later release says hello; after it disconnects, the host removes its socket and
    /// retires, so the next helper starts the installed host.
    @Test func hostRetiresWhenANewerHelperConnected() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = try HostServer(path: socket)
        var retired = false
        let session = HostSession(server: server, panel: RecordingPanel(), version: "0.1.0", retireAfterIdle: 0.2) { retired = true }
        session.start()
        defer { session.stop() }

        let client = try IPCClient.connect(path: socket, timeout: 1)
        try client.send(.hello(Hello(role: .pinentry, build: "0.2.0")))
        try await Task.sleep(for: .milliseconds(600))
        #expect(!retired)
        client.close()

        #expect(await waitUntil { retired })
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    /// The real pinentry asks the host for a card PIN and gets the submitted value back.
    @Test func pinentryRoundTrip() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = try HostServer(path: socket)
        let panel = RecordingPanel()
        panel.autoSubmit = "123456"
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        let pinentry = try PinentryProcess(socket: socket, home: directory)
        defer { pinentry.stop() }
        #expect(await pinentry.readLine()?.hasPrefix("OK") == true)
        pinentry.send("SETDESC Please unlock the card%0A%0A\u{1E}Number\u{1F}: 12 345 678%0AHolder\u{1F}: %0ACounter\u{1F}: 7")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("SETPROMPT PIN")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("GETPIN")
        #expect(await pinentry.readLine() == "D 123456")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("BYE")

        guard case .show(.pinEntry(var shown)) = panel.events.first else {
            Issue.record("no PIN prompt: \(panel.events)")
            return
        }
        #expect(shown.promptID != nil)
        shown.promptID = nil
        #expect(shown == PinRequest(operation: .unknown, cardSerial: "12345678"))
        #expect(await waitUntil { panel.events.last == .dismiss })
    }
}

/// Runs the built touchglass-pinentry against the test's host socket. Its fallback is /usr/bin/false,
/// so a fallback shows up as a failure instead of a real pinentry-mac window.
final class PinentryProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer: [UInt8] = []

    init(socket: String, home: String, environment extra: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: ProxyHarness.executable("touchglass-pinentry"))
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "TOUCHGLASS_CONFIG": home + "/no-such.conf",
            "TOUCHGLASS_SOCKET": socket,
            "TOUCHGLASS_HOST_APP": "none",
            "TOUCHGLASS_FALLBACK_PINENTRY": "/usr/bin/false",
        ].merging(extra) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock { self.buffer.append(contentsOf: data) }
        }
        try process.run()
    }

    func send(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Reads one line on the calling thread, for code that runs off the main actor.
    func readLineBlocking(timeout: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = takeLine() { return line }
            usleep(10_000)
        }
        return nil
    }

    private func takeLine() -> String? {
        lock.withLock {
            guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
            let bytes = buffer[..<newline]
            buffer.removeSubrange(...newline)
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    @MainActor
    func readLine(timeout: TimeInterval = 5) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line: String? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let bytes = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return String(decoding: bytes, as: UTF8.self)
            }
            if let line { return line }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
