import AppKit
import Testing
import TouchGlassCore
@testable import TouchGlassPanel

/// Drives `PanelController` with its real window, so a test sees what reaches the screen and not only the
/// state machine's effects.
@MainActor
@Suite(.serialized) struct PanelControllerTests {
    let pin = PanelState.pinEntry(PinRequest(operation: .sign, cardSerial: "12345678"))

    init() {
        _ = NSApplication.shared
    }

    func makeController() -> PanelController {
        let controller = PanelController(animationScale: 0.05)
        controller.muted = true
        return controller
    }

    func touch(_ operation: OperationKind = .sign) -> PanelState {
        .touchWait(TouchWait(operation: operation, cardSerial: "12345678", deadline: Date().addingTimeInterval(15), shownAt: Date()))
    }

    /// Lets the main queue and the animation completions run until `condition` holds or 2 s pass.
    func waitUntil(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func promptAfterHiddenTouchAndTimeoutIsOnScreen() async {
        let controller = makeController()
        controller.send(.show(touch()))
        #expect(controller.isPanelVisible)

        controller.send(.userHid)
        await waitUntil { !controller.isPanelVisible }
        #expect(!controller.isPanelVisible)

        controller.send(.show(.failure(.touchTimeout(seconds: 15))))
        #expect(!controller.isPanelVisible)
        controller.send(.show(pin))
        #expect(controller.isPanelVisible)
        #expect(controller.model.state == pin)
        controller.send(.dismiss)
    }

    @Test func nextTouchAfterHiddenSuccessIsOnScreen() async {
        let controller = makeController()
        controller.send(.show(touch()))
        controller.send(.userHid)
        await waitUntil { !controller.isPanelVisible }
        controller.send(.show(.success(.sign)))

        let next = touch(.sshLogin)
        controller.send(.show(next))
        #expect(controller.isPanelVisible)
        #expect(controller.model.state == next)
        controller.send(.dismiss)
    }

    @Test func promptDuringTheHideAnimationStaysOnScreen() async {
        let controller = makeController()
        controller.send(.show(touch()))
        controller.send(.userHid)
        controller.send(.show(pin))

        // Wait past the exit animation: its stale completion must neither order the window out nor clear the state.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.isPanelVisible)
        #expect(controller.model.state == pin)
        controller.send(.dismiss)
    }

    // MARK: Secure field

    func secureField(_ controller: PanelController) -> NSSecureTextField? {
        func find(_ view: NSView?) -> NSSecureTextField? {
            guard let view else { return nil }
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        return find(controller.panel.contentView)
    }

    /// Types into the secure field the way the field editor receives keystrokes.
    func type(_ text: String, into controller: PanelController) async throws {
        await waitUntil { secureField(controller) != nil }
        let field = try #require(secureField(controller))
        if controller.panel.firstResponder !== field.currentEditor() {
            controller.panel.makeFirstResponder(field)
        }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        await waitUntil { secureField(controller)?.stringValue == text }
    }

    func fieldText(_ controller: PanelController) async -> String? {
        try? await Task.sleep(for: .milliseconds(100))
        return secureField(controller)?.stringValue
    }

    @Test func aNewPINPromptStartsEmpty() async throws {
        let controller = makeController()
        let first = PinRequest(operation: .sign, cardSerial: "12345678", promptID: "r1")
        controller.send(.show(.pinEntry(first)))
        try await type("111111", into: controller)
        #expect(await fieldText(controller) == "111111")

        // A client label for the same prompt keeps the text.
        var labelled = first
        labelled.client = "git commit · example"
        controller.send(.show(.pinEntry(labelled)))
        #expect(await fieldText(controller) == "111111")

        controller.send(.show(.verifying(labelled)))
        controller.send(.show(.pinEntry(PinRequest(operation: .sshLogin, cardSerial: "12345678", promptID: "r2"))))
        #expect(await fieldText(controller) == "")
        controller.send(.dismiss)
    }

    @Test func aSecondPassphrasePromptStartsEmpty() async throws {
        let controller = makeController()
        controller.send(.show(.passphrase(PassphraseRequest(description: "First", promptID: "p1"))))
        try await type("old-phrase", into: controller)
        controller.send(.show(.passphrase(PassphraseRequest(description: "Second", promptID: "p2"))))
        #expect(await fieldText(controller) == "")
        controller.send(.dismiss)
    }
}
