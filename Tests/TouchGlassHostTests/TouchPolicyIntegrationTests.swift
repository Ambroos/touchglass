import Foundation
import ScdTestSupport
import Synchronization
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

/// Learning touch policies with the real proxy over fake-scdaemon and an in-process host session. The
/// query never runs gpg-connect-agent: a stand-in records the request.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct TouchPolicyIntegrationTests {
    final class RecordingQuery: CardPolicyQuerying {
        let requests = Mutex<[(serial: String, gnupg: GnuPGContext)]>([])
        let answer: [Int: TouchPolicy]?
        init(answer: [Int: TouchPolicy]?) { self.answer = answer }
        func query(serial: String, gnupg: GnuPGContext) -> [Int: TouchPolicy]? {
            requests.withLock { $0.append((serial, gnupg)) }
            return answer
        }
    }

    func temporaryStore() throws -> (CardPolicyStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touchglass-policy-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (CardPolicyStore(path: dir + "/cards.conf"), dir)
    }

    func storedText(_ store: CardPolicyStore) -> String {
        (try? String(contentsOfFile: store.path, encoding: .utf8)) ?? ""
    }

    /// `gpg --card-status` makes gpg-agent send LEARN: the host stores the policies, and a card whose
    /// signature key wants a touch every time shows the touch step at once, also right after a signature.
    @Test func learnedOnPolicyShowsEveryTouchAtOnce() async throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        card.touch_ms = 1000
        card.uif = ["%01+", "%01+", "%01+"]
        let harness = try ProxyHarness(card: card)
        let (store, dir) = try temporaryStore()
        defer { harness.cleanUp(); try? FileManager.default.removeItem(atPath: dir) }
        let server = try HostServer(path: harness.hostSocketPath)
        let panel = RecordingPanel()
        let query = RecordingQuery(answer: nil)
        let session = HostSession(server: server, panel: panel, policyStore: store, policyQuery: query)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        let agent = harness.agent
        #expect(await Task.detached { agent.transact("LEARN --force").isOK }.value)
        #expect(await waitUntil { storedText(store).contains("\(ProxyHarness.serial) = on on on") })

        #expect(await Task.detached { TouchCacheIntegrationTests.sign(agent) }.value)
        #expect(await waitUntil { panel.contains { $0 == .show(.success(.sign)) } })
        let before = panel.events.count
        let commandAt = Date()
        let signed = Task.detached { TouchCacheIntegrationTests.sign(agent) }
        // Inside the 15 s window, but the policy says every signature needs a touch: no hold-back.
        #expect(await waitUntil(timeout: 5) { panel.events[before...].contains { if case .show(.touchWait) = $0 { true } else { false } } })
        #expect(Date().timeIntervalSince(commandAt) < TouchTiming.cachedDetectionThreshold)
        #expect(await signed.value)
        // The policy is known, so the host never asked gpg-agent.
        #expect(query.requests.withLock { $0.isEmpty })
        #expect(harness.finish()?.status == 0)
    }

    /// An operation on a card without a known policy: once it ended and the host is idle, the host asks
    /// gpg-agent for that card, with the GnuPG context the proxy reported, and stores the answer.
    @Test func unknownCardIsQueriedAfterItsOperation() async throws {
        var card = ProxyHarness.Card()
        card.verified = [1]
        let harness = try ProxyHarness(card: card)
        let (store, dir) = try temporaryStore()
        defer { harness.cleanUp(); try? FileManager.default.removeItem(atPath: dir) }
        let server = try HostServer(path: harness.hostSocketPath)
        let panel = RecordingPanel()
        let query = RecordingQuery(answer: [1: .cached, 2: .on, 3: .off])
        let session = HostSession(server: server, panel: panel, policyStore: store, policyQuery: query)
        session.start()
        defer { session.stop() }

        try harness.start()
        _ = harness.handshake()
        let agent = harness.agent
        #expect(await Task.detached { TouchCacheIntegrationTests.sign(agent) }.value)
        #expect(await waitUntil { storedText(store).contains("\(ProxyHarness.serial) = cached on off") })
        let requests = query.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.serial == ProxyHarness.serial)
        #expect(session.coordinator.policies["12345678"]?.slots == [1: .cached, 2: .on, 3: .off])
        #expect(harness.finish()?.status == 0)
    }
}
