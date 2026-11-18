import Foundation
import Testing
import TouchGlassCore
import TouchGlassIPC
@testable import TouchGlassHost

@Suite struct HostCoordinatorClientTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let proxy: ConnectionID = 1
    let pinentry: ConnectionID = 2
    let cardDescription = "Please unlock the card\n\nNumber: 12 345 678\nHolder: \nCounter: 7"

    func panelEvents(_ outputs: [HostOutput]) -> [PanelEvent] {
        outputs.compactMap { if case .panel(let event) = $0 { event } else { nil } }
    }

    func queries(_ outputs: [HostOutput]) -> [HostOutput] {
        outputs.filter { if case .resolveClient = $0 { true } else { false } }
    }

    func start(_ coordinator: inout HostCoordinator, conn: String = "100:p", op: TouchGlassIPC.OperationKind = .sign, agent: Int32? = nil) -> [HostOutput] {
        coordinator.handle(.opStart(OpStart(conn: conn, op: op, slot: 1, serial: "D2760001240103040006123456780000", at: now.timeIntervalSince1970, agentPid: agent)), from: proxy, now: now)
    }

    /// The first operation a coordinator starts is number 1.
    func first(_ conn: String = "100:p") -> OperationRef {
        OperationRef(conn: conn, number: 1)
    }

    func touch(_ coordinator: inout HostCoordinator, conn: String = "100:p", timeoutMs: Int = 15_000) -> TouchGlassCore.TouchWait? {
        let events = panelEvents(coordinator.handle(.touchWait(TouchGlassIPC.TouchWait(conn: conn, timeoutMs: timeoutMs, at: now.timeIntervalSince1970)), from: proxy, now: now.addingTimeInterval(0.4)))
        guard case .show(.touchWait(let wait)) = events.first else { return nil }
        return wait
    }

    @Test func operationStartAsksForTheMatchingKindOfClient() {
        var coordinator = HostCoordinator()
        #expect(start(&coordinator, conn: "a", op: .sign) == [.resolveClient(.operation(OperationRef(conn: "a", number: 1)), .agentClient(ssh: false))])
        #expect(start(&coordinator, conn: "b", op: .decrypt) == [.resolveClient(.operation(OperationRef(conn: "b", number: 2)), .agentClient(ssh: false))])
        #expect(start(&coordinator, conn: "c", op: .auth, agent: 4321) == [.resolveClient(.operation(OperationRef(conn: "c", number: 3)), .agentClient(ssh: true, agent: 4321))])
    }

    @Test func aLateLabelFillsInTheTouchStepInPlace() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        let wait = try #require(touch(&coordinator))
        #expect(wait.client == nil)

        let updated = panelEvents(coordinator.clientResolved(.operation(first()), label: "git commit · example"))
        var expected = wait
        expected.client = "git commit · example"
        // Same deadline and start, so the countdown and escalation carry on.
        #expect(updated == [.show(.touchWait(expected))])
        // The same label again changes nothing.
        #expect(coordinator.clientResolved(.operation(first()), label: "git commit · example").isEmpty)
    }

    @Test func aLabelThatArrivesFirstShowsWithTheTouchStep() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        #expect(coordinator.clientResolved(.operation(first()), label: "ssh example-host").isEmpty)
        #expect(try #require(touch(&coordinator)).client == "ssh example-host")
    }

    @Test func noLabelOrAnEndedOperationChangesNothing() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        _ = try #require(touch(&coordinator))
        #expect(coordinator.clientResolved(.operation(first()), label: nil).isEmpty)
        _ = coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        #expect(coordinator.clientResolved(.operation(first()), label: "git commit · example").isEmpty)
    }

    @Test func aLabelForAnEndedOperationSkipsTheNextOneOnTheSameConnection() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        _ = coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .ok)), from: proxy, now: now)
        // The pipe session reuses its connection ID for the next operation.
        #expect(queries(start(&coordinator)) == [.resolveClient(.operation(OperationRef(conn: "100:p", number: 2)), .agentClient(ssh: false))])
        _ = try #require(touch(&coordinator))

        #expect(coordinator.clientResolved(.operation(first()), label: "git commit · stale").isEmpty)
        #expect(coordinator.clientResolved(.request(id: "gone", operation: first()), label: "git tag · stale").isEmpty)
        let current = panelEvents(coordinator.clientResolved(.operation(OperationRef(conn: "100:p", number: 2)), label: "ssh example-host"))
        guard case .show(.touchWait(let wait)) = current.first else {
            Issue.record("no update for the current operation")
            return
        }
        #expect(wait.client == "ssh example-host")
    }

    @Test func ownerLabelFillsThePINPromptAndCarriesToTheTouch() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        _ = coordinator.handle(.pinNeeded(ConnRef(conn: "100:p")), from: proxy, now: now)
        let prompt = coordinator.handle(.getPin(GetPin(id: "r1", desc: cardDescription, fields: CardFields(number: "12 345 678"), owner: "4242/501 example-host")), from: pinentry, now: now)
        #expect(queries(prompt) == [.resolveClient(.request(id: "r1", operation: first()), .owner(4242))])

        let filled = panelEvents(coordinator.clientResolved(.request(id: "r1", operation: first()), label: "git tag · example"))
        #expect(filled == [.show(.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678", client: "git tag · example", promptID: "r1")))])

        // The guess among the agent's clients arrives later and loses to the owner's answer.
        #expect(coordinator.clientResolved(.operation(first()), label: "gpg").isEmpty)

        let submitted = panelEvents(coordinator.handle(.submit("975310")))
        #expect(submitted == [.show(.verifying(PinRequest(operation: .sign, cardSerial: "12345678", client: "git tag · example", promptID: "r1")))])
        #expect(try #require(touch(&coordinator)).client == "git tag · example")
    }

    @Test func passphrasePromptGetsTheOwnerLabel() {
        var coordinator = HostCoordinator()
        let prompt = coordinator.handle(.getPin(GetPin(id: "p1", desc: "Please enter the passphrase", owner: "77/501 example-host")), from: pinentry, now: now)
        #expect(queries(prompt) == [.resolveClient(.request(id: "p1", operation: nil), .owner(77))])
        #expect(panelEvents(coordinator.clientResolved(.request(id: "p1", operation: nil), label: "gpg")) == [.show(.passphrase(PassphraseRequest(description: "Please enter the passphrase", client: "gpg", promptID: "p1")))])
    }

    @Test func touchTimeoutSettingOverridesTheProxy() throws {
        var coordinator = HostCoordinator(touchTimeout: 25)
        _ = start(&coordinator)
        let wait = try #require(touch(&coordinator, timeoutMs: 15_000))
        #expect(wait.deadline == now.addingTimeInterval(25))
        #expect(wait.duration == 25)
        let end = panelEvents(coordinator.handle(.opEnd(OpEnd(conn: "100:p", result: .timeout)), from: proxy, now: now))
        #expect(end == [.show(.failure(.touchTimeout(seconds: 25)))])
    }

    @Test func withoutTheSettingTheProxyTimeoutCounts() throws {
        var coordinator = HostCoordinator()
        _ = start(&coordinator)
        let wait = try #require(touch(&coordinator, timeoutMs: 20_000))
        #expect(wait.deadline == now.addingTimeInterval(20))
        #expect(wait.duration == 20)
    }
}

@Suite struct HostSettingsTests {
    @Test func defaults() {
        let settings = HostSettings.parse("")
        #expect(settings.showClient)
        #expect(settings.touchTimeout == nil)
    }

    @Test func parsesShowClientAndTouchTimeout() {
        let settings = HostSettings.parse("show-client = no\ntouch-timeout = 20\n")
        #expect(!settings.showClient)
        #expect(settings.touchTimeout == 20)
        #expect(HostSettings.parse("show-client=yes").showClient)
    }

    @Test func ignoresInvalidValues() {
        let settings = HostSettings.parse("show-client = maybe\ntouch-timeout = 0\n")
        #expect(settings.showClient)
        #expect(settings.touchTimeout == nil)
        #expect(HostSettings.parse("touch-timeout = soon").touchTimeout == nil)
        #expect(HostSettings.parse("touch-timeout = 9999").touchTimeout == nil)
    }
}

@Suite struct ClientPresentationTests {
    @Test func clientLineIsNotAnnounced() {
        let wait = TouchGlassCore.TouchWait.detected(operation: .sign, cardSerial: "12345678", client: "git commit · example")
        let presentation = PanelPresentation(.touchWait(wait))
        #expect(presentation.clientLine == "git commit · example")
        #expect(presentation.reservesClientLine)
        #expect(!presentation.announcement.contains("git commit"))
    }

    @Test func cardStatesReserveTheLineAndOthersDoNot() {
        #expect(PanelPresentation(.pinEntry(PinRequest(operation: .sign, cardSerial: ""))).reservesClientLine)
        #expect(PanelPresentation(.success(.sign)).reservesClientLine)
        #expect(!PanelPresentation(.failure(.wrongPIN)).reservesClientLine)
        #expect(!PanelPresentation(.message(TouchGlassCore.MessageRequest(title: "t", detail: "d"))).reservesClientLine)
    }

    @Test func ringFollowsTheTouchDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let wait = TouchGlassCore.TouchWait(operation: .sign, cardSerial: "", deadline: now.addingTimeInterval(10), shownAt: now, duration: 20)
        #expect(wait.fractionRemaining(at: now) == 0.5)
    }
}
