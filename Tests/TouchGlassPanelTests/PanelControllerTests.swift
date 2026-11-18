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
}
