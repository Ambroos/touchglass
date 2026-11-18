import Darwin
import Foundation
import ScdTestSupport
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

@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
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

        #expect(panel.events.first == .show(.pinEntry(PinRequest(operation: .unknown, cardSerial: "12345678"))))
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

    init(socket: String, home: String) throws {
        process.executableURL = URL(fileURLWithPath: ProxyHarness.executable("touchglass-pinentry"))
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "TOUCHGLASS_CONFIG": home + "/no-such.conf",
            "TOUCHGLASS_SOCKET": socket,
            "TOUCHGLASS_HOST_APP": "none",
            "TOUCHGLASS_FALLBACK_PINENTRY": "/usr/bin/false",
        ]
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
