import AppKit
import SwiftUI
import TouchGlassCore
import TouchGlassPanel

struct DemoOptions {
    var touchAfter: TimeInterval = 4
    /// Submit PIN and passphrase fields by themselves after this many seconds.
    var autoSubmitAfter: TimeInterval?
    var animationScale: Double = 1
    var showControls = true
    var focusReport = false
    var settings = HostSettings()
    /// Replaces each scenario's sample client label.
    var client: String?
    /// Forces the app's appearance, so both looks can be reviewed without changing the system setting.
    var colorScheme: NSAppearance.Name?
}

enum DemoScenario: String, CaseIterable {
    case sign
    case touch
    case timeout
    case wrongPIN = "wrong-pin"
    case ssh
    case decrypt
    case blocked
    case passphrase
    case insertCard = "insert-card"
    case message
    case removed
    case error
    case client
    case all

    static let sequence: [DemoScenario] = [
        .sign, .touch, .ssh, .decrypt, .wrongPIN, .blocked, .passphrase, .insertCard, .message, .removed, .error, .client, .timeout,
    ]

    var summary: String {
        switch self {
        case .sign: "PIN entry, verifying, touch, success"
        case .touch: "touch only, touched after a few seconds"
        case .timeout: "full touch countdown with escalation, then the timeout state"
        case .wrongPIN: "PIN entry with 2 attempts left, verifying, wrong PIN"
        case .ssh: "PIN for SSH login, touch, logged in"
        case .decrypt: "PIN with 1 attempt left, touch, decrypted"
        case .blocked: "PIN entry, verifying, PIN blocked"
        case .passphrase: "soft-key passphrase, rejected once with a shake, then accepted"
        case .insertCard: "confirm prompt asking to insert the YubiKey"
        case .message: "message with an OK button"
        case .removed: "touch, then the YubiKey is removed"
        case .error: "touch, then a card error"
        case .client: "PIN, then touch, with a long client label that arrives late"
        case .all: "every scenario in sequence"
        }
    }
}

/// Events from the panel and the demo controls that a scenario waits for.
private enum DemoEvent: Equatable {
    case submitted
    case cancelled
    case confirmed
    case touched
    case dismissed
}

/// Delivers panel actions to the scenario script one at a time.
@MainActor
private final class DemoInbox {
    private var waiter: (token: Int, continuation: CheckedContinuation<DemoEvent?, Never>)?
    private var token = 0

    func post(_ event: DemoEvent) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: event)
    }

    /// The next of `accepted`, or `nil` after `timeout`.
    func next(_ accepted: Set<DemoEvent>, timeout: TimeInterval?) async -> DemoEvent? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let remaining = deadline.map { $0.timeIntervalSinceNow }
            if let remaining, remaining <= 0 { return nil }
            let event = await nextAny(timeout: remaining)
            guard let event else { return nil }
            if accepted.contains(event) { return event }
        }
    }

    private func nextAny(timeout: TimeInterval?) async -> DemoEvent? {
        token += 1
        let current = token
        return await withCheckedContinuation { continuation in
            waiter = (current, continuation)
            if let timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let waiter = self.waiter, waiter.token == current else { return }
                    self.waiter = nil
                    waiter.continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
@Observable
final class DemoControlModel {
    var scenario = ""
    var touchEnabled = false
    @ObservationIgnored var touch: () -> Void = {}
}

/// Runs scripted scenarios against a `PanelController`. No gpg, no card: touch is a timer,
/// the Simulate Touch button, or Space while the demo controls window is key.
@MainActor
final class DemoRunner {
    private static let serial = "12345678"
    private static let verifyDuration: TimeInterval = 1.2

    private let options: DemoOptions
    private let controller: PanelController
    private let inbox = DemoInbox()
    private let controls = DemoControlModel()
    private var controlsWindow: NSPanel?

    init(options: DemoOptions) {
        self.options = options
        controller = PanelController(animationScale: options.animationScale, settings: options.settings)

        var actions = PanelActions()
        // The demo discards the secret without reading it.
        actions.submitSecret = { [inbox] _ in inbox.post(.submitted) }
        actions.cancel = { [inbox] in inbox.post(.cancelled) }
        actions.confirm = { [inbox] in inbox.post(.confirmed) }
        actions.dismiss = { [inbox] in inbox.post(.dismissed) }
        controller.actions = actions
        controls.touch = { [inbox] in inbox.post(.touched) }

        if options.showControls { makeControlsWindow() }
    }

    func run(_ scenario: DemoScenario) async {
        if scenario == .all {
            for (index, next) in DemoScenario.sequence.enumerated() {
                if index > 0 { await sleep(1.2) }
                await runOne(next)
            }
        } else {
            await runOne(scenario)
        }
        controlsWindow?.orderOut(nil)
    }

    /// The sample label each scenario shows, as the host would infer it.
    private func client(_ scenario: DemoScenario) -> String? {
        if let client = options.client { return client }
        switch scenario {
        case .touch: return "git rebase · touchglass"
        case .ssh: return "ssh build-box"
        case .decrypt: return "gpg"
        case .client: return "git push origin · an-example-repository-with-a-rather-long-name"
        case .passphrase, .insertCard, .message, .all: return nil
        default: return "git commit · touchglass"
        }
    }

    private func runOne(_ scenario: DemoScenario) async {
        controls.scenario = scenario.rawValue
        let client = client(scenario)
        switch scenario {
        case .sign:
            guard await pinStep(PinRequest(operation: .sign, cardSerial: Self.serial, minimumLengthOverride: 1, client: client)) else { return }
            await touchStep(.sign, client: client)
        case .touch:
            await touchStep(.sign, client: client)
        case .timeout:
            await touchStep(.sign, client: client, outcome: .timeout)
        case .wrongPIN:
            guard await pinStep(PinRequest(operation: .sign, cardSerial: Self.serial, attemptsLeft: 2, minimumLengthOverride: 1, client: client)) else { return }
            await failure(.wrongPIN)
        case .ssh:
            guard await pinStep(PinRequest(operation: .sshLogin, cardSerial: Self.serial, minimumLengthOverride: 1, client: client)) else { return }
            await touchStep(.sshLogin, client: client)
        case .decrypt:
            guard await pinStep(PinRequest(operation: .decrypt, cardSerial: Self.serial, attemptsLeft: 1, minimumLengthOverride: 1, client: client)) else { return }
            await touchStep(.decrypt, client: client)
        case .blocked:
            guard await pinStep(PinRequest(operation: .sign, cardSerial: Self.serial, attemptsLeft: 1, minimumLengthOverride: 1, client: client)) else { return }
            await failure(.pinBlocked)
        case .client:
            // The host shows the panel at once and fills the label in when its lookup finishes.
            guard await pinStep(PinRequest(operation: .sign, cardSerial: Self.serial, minimumLengthOverride: 1), lateClient: client) else { return }
            await touchStep(.sign, client: client)
        case .passphrase:
            await passphraseStep()
        case .insertCard:
            await confirmStep(.confirm(ConfirmRequest(
                purpose: .insertCard,
                title: "Insert your YubiKey",
                detail: "Please insert the card with serial number:\n\n12345678"
            )))
        case .message:
            await confirmStep(.message(MessageRequest(
                title: "Key added",
                detail: "The key ABCD 1234 ABCD 1234 is now available for SSH."
            )))
        case .removed:
            await touchStep(.sign, client: client, outcome: .failure(.cardRemoved, after: 3))
        case .error:
            await touchStep(.sign, client: client, outcome: .failure(.other("Card error"), after: 2))
        case .all:
            break
        }
    }

    // MARK: Steps

    /// Returns false if the user cancelled.
    private func pinStep(_ request: PinRequest, lateClient: String? = nil) async -> Bool {
        var request = request
        controller.send(.show(.pinEntry(request)))
        if let lateClient {
            await sleep(0.6)
            request.client = lateClient
            controller.send(.show(.pinEntry(request)))
        }
        if options.focusReport { reportFocus(after: 0.6) }
        let event = await inbox.next([.submitted, .cancelled], timeout: options.autoSubmitAfter)
        if event == .cancelled {
            controller.send(.dismiss)
            await sleep(0.6)
            return false
        }
        controller.send(.show(.verifying(request)))
        await sleep(Self.verifyDuration)
        return true
    }

    private enum TouchOutcome {
        case touched
        case timeout
        case failure(Failure, after: TimeInterval)
    }

    private func touchStep(_ operation: OperationKind, client: String? = nil, outcome: TouchOutcome = .touched) async {
        let wait = TouchWait.detected(operation: operation, cardSerial: Self.serial, client: client)
        controller.send(.show(.touchWait(wait)))
        if options.focusReport { reportFocus(after: 1.0, label: "touch") }
        controls.touchEnabled = true
        if let controlsWindow, controlsWindow.isVisible { controlsWindow.makeKey() }
        defer { controls.touchEnabled = false }

        let untilDeadline = wait.remaining(at: Date())
        switch outcome {
        case .touched:
            // A touch from the controls or the timer, whichever comes first; the card times out otherwise.
            let touched = await inbox.next([.touched], timeout: min(options.touchAfter, untilDeadline))
            if touched != nil || options.touchAfter < untilDeadline {
                controls.touchEnabled = false
                controller.send(.show(.success(operation, client: wait.client)))
                await waitUntilClosed()
            } else {
                await failure(.touchTimeout(seconds: Int(TouchTiming.cardTimeout)))
            }
        case .timeout:
            // Touching is still possible, to try the success path from a late phase.
            if await inbox.next([.touched], timeout: untilDeadline) != nil {
                controls.touchEnabled = false
                controller.send(.show(.success(operation, client: wait.client)))
                await waitUntilClosed()
            } else {
                await failure(.touchTimeout(seconds: Int(TouchTiming.cardTimeout)))
            }
        case .failure(let failure, let after):
            _ = await inbox.next([], timeout: after)
            await self.failure(failure)
        }
    }

    private func failure(_ failure: Failure) async {
        controller.send(.show(.failure(failure)))
        await waitUntilClosed()
    }

    private func passphraseStep() async {
        let description = "Please enter the passphrase to unlock the OpenPGP secret key:\n\"Example User <user@example.com>\""
        controller.send(.show(.passphrase(PassphraseRequest(description: description))))
        if options.focusReport { reportFocus(after: 0.6) }
        guard await inbox.next([.submitted, .cancelled], timeout: options.autoSubmitAfter) == .submitted else {
            controller.send(.dismiss)
            await sleep(0.6)
            return
        }
        await sleep(0.4)
        controller.send(.show(.passphrase(PassphraseRequest(description: description, error: "Bad Passphrase (try 2 of 3)"))))
        controller.shakeField()
        _ = await inbox.next([.submitted, .cancelled], timeout: options.autoSubmitAfter)
        controller.send(.dismiss)
        await sleep(0.6)
    }

    private func confirmStep(_ state: PanelState) async {
        controller.send(.show(state))
        if options.focusReport { reportFocus(after: 0.6) }
        _ = await inbox.next([.confirmed, .cancelled], timeout: options.autoSubmitAfter.map { $0 + 1 })
        controller.send(.dismiss)
        await sleep(0.6)
    }

    // MARK: Helpers

    private func waitUntilClosed() async {
        while controller.machine.state != nil {
            await sleep(0.05)
        }
        // Let the exit animation finish.
        await sleep(0.6 * options.animationScale)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Prints whether the panel took key focus while another app stays frontmost. Never prints field content.
    private func reportFocus(after delay: TimeInterval, label: String = "prompt") {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [controller] in
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            print("focus (\(label)): panelKey=\(controller.isPanelKey) appActive=\(NSApp.isActive) frontmostApp=\(frontmost) firstResponder=\(controller.firstResponderDescription)")
        }
    }

    private func makeControlsWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "TouchGlass demo"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DemoControlsView(model: controls))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - 130, y: visible.minY + 40))
        }
        panel.orderFrontRegardless()
        controlsWindow = panel
    }
}

private struct DemoControlsView: View {
    let model: DemoControlModel

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: model.scenario)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.touch()
            } label: {
                Text(verbatim: "Simulate touch")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.touchEnabled)
        }
        .padding(.horizontal, 16)
        .frame(width: 260, height: 64)
    }
}
