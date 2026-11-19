import Darwin
import Foundation
import ScdTestSupport
import Synchronization
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// The touch cache window and the unified log, with the real proxy over fake-scdaemon, the real pinentry and
/// an in-process host session.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct TouchCacheIntegrationTests {
    /// Signs once as gpg-agent does. `pin` answers NEEDPIN.
    nonisolated static func sign(_ agent: AgentDriver, pin: String? = nil) -> Bool {
        let grip = ProxyHarness.signGrip
        _ = agent.transact("SERIALNO --all")
        _ = agent.transact("KEYINFO \(grip)")
        _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
        return agent.transact("PKSIGN --hash=sha512 \(grip)", inquiries: AgentDriver.standardInquiries(pin: pin)).isOK
    }

    static func touchWaits(_ panel: RecordingPanel) -> [TouchGlassCore.TouchWait] {
        panel.events.compactMap { if case .show(.touchWait(let wait)) = $0 { wait } else { nil } }
    }

    /// After a touched signature, a cached one that takes 0.8 s shows no panel at all.
    @Test func cachedSignatureInsideTheWindowShowsNothing() async throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 900
        card.touch_cache_ms = 15_000
        card.cached_ms = 800
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
        #expect(await Task.detached { Self.sign(agent) }.value)
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })
        #expect(Self.touchWaits(panel).count == 1)
        let before = panel.events.count

        #expect(await Task.detached { Self.sign(agent) }.value)
        // Past the longer detection delay of the second signature.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!panel.events[before...].contains { if case .show = $0 { true } else { false } }, "events: \(panel.events[before...])")
        #expect(harness.finish()?.status == 0)
    }

    /// Inside the window, a signature that does need a touch shows the panel after the longer delay, with
    /// the countdown running from the card command.
    @Test func touchInsideTheWindowShowsLateWithAnHonestCountdown() async throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 2500
        // The card forgets the touch sooner than the host's window.
        card.touch_cache_ms = 500
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
        #expect(await Task.detached { Self.sign(agent) }.value)
        try await Task.sleep(for: .milliseconds(700))
        let commandAt = Date()
        #expect(await Task.detached { Self.sign(agent) }.value)

        let waits = Self.touchWaits(panel)
        #expect(waits.count == 2)
        let second = try #require(waits.last)
        // Shown about 1.5 s after the command, counting down from the command.
        #expect(abs(second.shownAt.timeIntervalSince(commandAt) - TouchTiming.cachedDetectionThreshold) < 0.4)
        #expect(abs(second.deadline.timeIntervalSince(commandAt) - TouchTiming.cardTimeout) < 0.4)
        #expect(harness.finish()?.status == 0)
    }

    /// A PIN flow across the proxy, the pinentry and the host writes no secret to the log: not the PIN in any
    /// encoding, not the hash data, not the PIN cache value and not the signature.
    @Test func pinFlowLogsNoSecret() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // A fake test PIN, distinctive enough to find in any log line.
        let pin = "Zq9-fake-PIN"
        let logPath = directory + "/mirror.log"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        TouchGlassLog.mirror(toFile: logPath)
        defer { TouchGlassLog.mirror(toFile: nil) }

        var card = ProxyHarness.Card()
        card.pin = pin
        card.touch_ms = 600
        let mirror = [TouchGlassLog.mirrorEnvironmentKey: logPath]
        let harness = try ProxyHarness(card: card, hostPath: socket, extraEnvironment: mirror)
        defer { harness.cleanUp() }
        let server = try HostServer(path: socket)
        let panel = RecordingPanel()
        panel.autoSubmit = pin
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        let agent = harness.agent
        let grip = ProxyHarness.signGrip
        let signed = await Task.detached { () -> Bool in
            _ = agent.transact("SERIALNO --all")
            _ = agent.transact("KEYINFO \(grip)")
            _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
            let reply = agent.transact("PKSIGN --hash=sha512 \(grip)") { keyword, _ in
                guard keyword == "NEEDPIN", let pinentry = try? PinentryProcess(socket: socket, home: directory, environment: mirror) else { return nil }
                defer { pinentry.stop() }
                var answer: String?
                func exchange(_ command: String) {
                    pinentry.send(command)
                    while let line = pinentry.readLineBlocking() {
                        if line.hasPrefix("D ") { answer = String(line.dropFirst(2)) }
                        if line.hasPrefix("OK") || line.hasPrefix("ERR") { break }
                    }
                }
                _ = pinentry.readLineBlocking()
                exchange("SETDESC Please unlock the card%0A%0A\u{1E}Number\u{1F}: 12 345 678%0AHolder\u{1F}: %0ACounter\u{1F}: 7")
                exchange("GETPIN")
                exchange("BYE")
                return answer.map(AgentDriver.pinAnswer)
            }
            return reply.isOK
        }.value
        #expect(signed)
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })
        #expect(harness.finish()?.status == 0)

        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        // Every component wrote to the log, so the checks below cover all three.
        for category in ["scdaemon[", "host[", "pinentry["] {
            #expect(log.contains(category), "no \(category) lines in:\n\(log)")
        }
        #expect(log.contains("PIN requested"))
        #expect(log.contains("panel: verifying"))
        let secrets = [
            pin,
            Data(pin.utf8).base64EncodedString(),
            Data(pin.utf8).map { String(format: "%02X", $0) }.joined(),
            String(repeating: "AB", count: 8),
            "00112233445566778899AABBCCDDEEFF",
        ]
        for secret in secrets {
            #expect(!log.localizedCaseInsensitiveContains(secret), "log contains \(secret)")
        }
    }
}
