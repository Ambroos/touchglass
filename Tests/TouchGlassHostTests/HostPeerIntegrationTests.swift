import Darwin
import Foundation
import ScdTestSupport
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// The host with its real peer check, against the built helpers. A temporary directory stands in for
/// the app's `Contents/MacOS`.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct HostPeerIntegrationTests {
    /// Copies `sources` into a new directory under the helpers' names.
    func helperDirectory(pinentry: String, scdaemon: String) throws -> String {
        let directory = NSTemporaryDirectory() + "tg-trusted-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try replace(directory + "/touchglass-pinentry", with: pinentry)
        try replace(directory + "/touchglass-scdaemon", with: scdaemon)
        return directory
    }

    func replace(_ target: String, with source: String) throws {
        try? FileManager.default.removeItem(atPath: target)
        try FileManager.default.copyItem(atPath: source, toPath: target)
    }

    /// After `brew upgrade`, the proxy of the earlier release keeps running until scdaemon restarts, and
    /// the host that it starts trusts only the next release's helpers. The proxy still drives the touch
    /// panel.
    @Test func aProxyOfTheEarlierReleaseStillShowsTheTouch() async throws {
        let proxyBinary = ProxyHarness.executable("touchglass-scdaemon")
        let trusted = try helperDirectory(pinentry: ProxyHarness.executable("touchglass-pinentry"), scdaemon: proxyBinary)
        defer { try? FileManager.default.removeItem(atPath: trusted) }
        let signatures = HelperSignatures(directory: trusted)

        var card = ProxyHarness.Card()
        card.touch_ms = 900
        let harness = try ProxyHarness(card: card)
        defer { harness.cleanUp() }
        let server = try HostServer(path: harness.hostSocketPath, peerVerifier: signatures)
        let panel = RecordingPanel()
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        // The upgrade: the next release's helper, with another hash, replaces the running proxy's file.
        try replace(trusted + "/touchglass-scdaemon", with: "/bin/cat")

        let agent = harness.agent
        let grip = ProxyHarness.signGrip
        let operation = Task.detached {
            _ = agent.transact("SERIALNO --all")
            _ = agent.transact("KEYINFO \(grip)")
            _ = agent.transact("SETDATA 3051300D060960864801650304020305000440" + String(repeating: "AB", count: 64))
            return agent.transact("PKSIGN --hash=sha512 \(grip)", inquiries: AgentDriver.standardInquiries(pin: "123456")).isOK
        }
        #expect(await waitUntil { panel.contains { if case .show(.touchWait) = $0 { true } else { false } } })
        #expect(await operation.value)
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })
        #expect(!session.coordinator.retiring)
        #expect(harness.finish()?.status == 0)
    }

    /// A pinentry whose code isn't a trusted helper's is closed at its hello and never shows a prompt.
    /// Its fallback, `/usr/bin/false`, then fails the request.
    @Test func anUnverifiedPinentryShowsNoPrompt() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let trusted = try helperDirectory(pinentry: "/bin/cat", scdaemon: "/bin/cat")
        defer { try? FileManager.default.removeItem(atPath: trusted) }
        let server = try HostServer(path: socket, peerVerifier: HelperSignatures(directory: trusted))
        let panel = RecordingPanel()
        let session = HostSession(server: server, panel: panel)
        session.start()
        defer { session.stop() }

        let pinentry = try PinentryProcess(socket: socket, home: directory)
        defer { pinentry.stop() }
        #expect(await pinentry.readLine()?.hasPrefix("OK") == true)
        pinentry.send("SETDESC Please enter the passphrase")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("GETPIN")
        #expect(await pinentry.readLine(timeout: 10)?.hasPrefix("ERR") == true)
        #expect(panel.events.isEmpty)
    }

    /// The trusted pinentry gets its prompt, and the asker line starts from its PID: this test process
    /// started it, not gpg-agent.
    @Test func aVerifiedPinentryGetsItsPromptWithTheAskerLine() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let trusted = try helperDirectory(pinentry: ProxyHarness.executable("touchglass-pinentry"), scdaemon: "/bin/cat")
        defer { try? FileManager.default.removeItem(atPath: trusted) }
        let server = try HostServer(path: socket, peerVerifier: HelperSignatures(directory: trusted))
        let panel = RecordingPanel()
        let session = HostSession(server: server, panel: panel, resolver: ClientResolver(budget: .seconds(2)))
        session.start()
        defer { session.stop() }

        let pinentry = try PinentryProcess(socket: socket, home: directory)
        defer { pinentry.stop() }
        #expect(await pinentry.readLine()?.hasPrefix("OK") == true)
        pinentry.send("SETDESC Please enter the passphrase")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("GETPIN")
        #expect(await waitUntil {
            panel.contains {
                if case .show(.passphrase(let request)) = $0 { request.client?.hasSuffix(", not through gpg-agent") == true } else { false }
            }
        })
        panel.actions.submitSecret("fake-passphrase")
        #expect(await pinentry.readLine() == "D fake-passphrase")
        #expect(await pinentry.readLine() == "OK")
        pinentry.send("BYE")
    }
}
