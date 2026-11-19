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

    /// Off every screen, so the tests put nothing in front of the person at the Mac.
    static let offScreen = NSPoint(x: -30_000, y: -30_000)

    /// A controller whose panel opens off screen and fully transparent. The window still orders in and
    /// out, takes key status and runs its animations, so the tests see what the controller does.
    func makeController(animationScale: Double = 0.05) -> PanelController {
        let controller = PanelController(animationScale: animationScale)
        controller.muted = true
        controller.testOrigin = Self.offScreen
        controller.panel.alphaValue = 0
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

    // MARK: Keyboard

    /// A test process can't take key status, so this checks that the window may no longer become key; the
    /// hand-back of key status itself needs a manual check.
    @Test func aFailedPINLetsGoOfTheKeyboardAndStaysOnScreen() async {
        let controller = makeController()
        let request = PinRequest(operation: .sign, cardSerial: "12345678", promptID: "r1")
        controller.send(.show(.pinEntry(request)))
        #expect(controller.panel.allowsKey)
        controller.send(.show(.verifying(request)))
        controller.send(.show(.failure(.wrongPIN)))
        #expect(!controller.panel.allowsKey)
        #expect(controller.isPanelVisible)
        controller.send(.dismiss)
    }

    // MARK: Close grace

    /// The answer is in when the prompt starts to linger: the window may no longer become key, and clicks
    /// pass through it. The next prompt takes both back.
    @Test func aLingeringPromptLetsGoOfTheKeyboardAndTakesNoClicks() async {
        let controller = makeController()
        controller.send(.show(pin))
        #expect(controller.panel.allowsKey)
        #expect(!controller.panel.ignoresMouseEvents)
        controller.send(.dismiss)
        #expect(controller.isPanelVisible)
        #expect(!controller.panel.allowsKey)
        #expect(controller.panel.ignoresMouseEvents)
        controller.send(.show(pin))
        #expect(controller.panel.allowsKey)
        #expect(!controller.panel.ignoresMouseEvents)
        controller.send(.userClosed)
    }

    @Test func dismissKeepsThePanelForTheGraceThenCloses() async throws {
        let controller = makeController()
        controller.send(.show(touch()))
        controller.send(.dismiss)
        try await Task.sleep(for: .seconds(TouchTiming.closeGrace / 2))
        #expect(controller.isPanelVisible)
        await waitUntil { !controller.isPanelVisible }
        #expect(!controller.isPanelVisible)
        #expect(controller.model.state == nil)
    }

    @Test func aStateWithinTheGraceReplacesTheLastOne() async throws {
        let controller = makeController()
        controller.send(.show(.success(.sign)))
        controller.send(.dismiss)
        try await Task.sleep(for: .seconds(TouchTiming.closeGrace / 2))
        let next = touch(.sshLogin)
        controller.send(.show(next))
        try await Task.sleep(for: .seconds(TouchTiming.closeGrace + 0.3))
        #expect(controller.isPanelVisible)
        #expect(controller.model.state == next)
        #expect(controller.model.surfaceShown)
        controller.send(.dismiss)
    }

    /// At full animation length, a state that arrives while the exit runs turns it around: the window
    /// never orders out, and the stale exit completion leaves the new state alone.
    @Test func aStateDuringTheExitAnimationReversesIt() async throws {
        let controller = makeController(animationScale: 1)
        controller.send(.show(touch()))
        controller.send(.dismiss)
        try await Task.sleep(for: .seconds(TouchTiming.closeGrace + 0.1))
        #expect(controller.isPanelVisible)
        #expect(!controller.model.surfaceShown)
        controller.send(.show(pin))
        #expect(controller.model.surfaceShown)
        try await Task.sleep(for: .seconds(0.8))
        #expect(controller.isPanelVisible)
        #expect(controller.model.state == pin)
        controller.send(.dismiss)
    }

    @Test func aClickOnAnErrorClosesAtOnce() async {
        let controller = makeController()
        controller.send(.show(.failure(.wrongPIN)))
        controller.model.actions.dismiss()
        await waitUntil { !controller.isPanelVisible }
        #expect(!controller.isPanelVisible)
        #expect(controller.machine.lingering == nil)
    }

    // MARK: Centred animation

    /// How far the most off-centre panel-sized layer is from the window's centre, in points, and the
    /// smallest width of such a layer. Panel-sized means at least half the panel in each dimension,
    /// so this covers the glass and the content's layer but not single controls.
    func panelLayerGeometry(_ controller: PanelController) -> (offCentre: CGFloat, minWidth: CGFloat) {
        guard let root = controller.panel.contentView?.layer else { return (0, .infinity) }
        let centre = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        var result: (offCentre: CGFloat, minWidth: CGFloat) = (0, .infinity)
        func walk(_ layer: CALayer) {
            if layer !== root, layer.bounds.width >= PanelMetrics.size.width / 2, layer.bounds.height >= PanelMetrics.size.height / 2 {
                let frame = layer.convert(layer.bounds, to: root)
                result.offCentre = max(result.offCentre, abs(frame.midX - centre.x), abs(frame.midY - centre.y))
                result.minWidth = min(result.minWidth, frame.width)
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return result
    }

    /// Samples the panel's layers for `seconds`. SwiftUI drives these animations by setting the
    /// layers' model values on every frame, so the samples see the animation in progress.
    func sampleGeometry(_ controller: PanelController, for seconds: TimeInterval) async -> (offCentre: CGFloat, minWidth: CGFloat) {
        var result: (offCentre: CGFloat, minWidth: CGFloat) = (0, .infinity)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(8))
            let sample = panelLayerGeometry(controller)
            result = (max(result.offCentre, sample.offCentre), min(result.minWidth, sample.minWidth))
        }
        return result
    }

    /// The glass and its content scale about the panel's centre in every transition. A scale
    /// transition on the glass view puts the content at the scaled glass's corner and scales it from
    /// there, so the content moves in from the bottom right.
    @Test(arguments: [PanelAppearance.readable, .smoked])
    func everyTransitionStaysCentred(appearance: PanelAppearance) async throws {
        let controller = PanelController(animationScale: 1, settings: HostSettings(appearance: appearance))
        controller.muted = true
        controller.testOrigin = Self.offScreen
        controller.panel.alphaValue = 0
        let tolerance: CGFloat = 0.5

        controller.send(.show(pin))
        let open = await sampleGeometry(controller, for: 0.7)
        #expect(open.offCentre < tolerance, "open")
        // The samples caught the entrance's scale, so the check above means something. A headless CI runner
        // (GitHub sets CI) renders no animation frames, so there the samples only see the final size.
        if ProcessInfo.processInfo.environment["CI"] == nil {
            #expect(open.minWidth < PanelMetrics.size.width * 0.99)
        }

        controller.send(.show(touch()))
        #expect(await sampleGeometry(controller, for: 0.3).offCentre < tolerance, "PIN to touch")
        controller.send(.show(.success(.sign)))
        #expect(await sampleGeometry(controller, for: 0.3).offCentre < tolerance, "touch to success")
        controller.send(.dismiss)
        controller.send(.show(touch(.sshLogin)))
        #expect(await sampleGeometry(controller, for: 0.3).offCentre < tolerance, "success to a touch within the grace")

        controller.send(.userClosed)
        #expect(await sampleGeometry(controller, for: 0.15).offCentre < tolerance, "close")
        controller.send(.show(pin))
        #expect(await sampleGeometry(controller, for: 0.6).offCentre < tolerance, "reverse")

        controller.send(.userClosed)
        #expect(await sampleGeometry(controller, for: 0.6).offCentre < tolerance, "close")
        await waitUntil { !controller.isPanelVisible }
        #expect(!controller.isPanelVisible)
    }

    /// The window server lists the test panel, but nowhere on a screen and with alpha 0.
    @Test func testPanelsStayOffEveryScreen() async throws {
        let controller = makeController()
        controller.send(.show(pin))
        #expect(controller.isPanelVisible)
        let number = controller.panel.windowNumber
        func serverInfo() -> [String: Any]? {
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.first { ($0[kCGWindowNumber as String] as? Int) == number }
        }
        func bounds(_ info: [String: Any]?) -> CGRect {
            guard let dictionary = info?[kCGWindowBounds as String] else { return .zero }
            return CGRect(dictionaryRepresentation: dictionary as! CFDictionary) ?? .zero
        }
        // The window server takes the new frame and alpha after the run loop commits them.
        await waitUntil { bounds(serverInfo()).width > 0 }
        let info = try #require(serverInfo())
        let frame = bounds(info)
        #expect(frame.width > 0)
        #expect((info[kCGWindowAlpha as String] as? Double) == 0)
        // Window server coordinates have their origin at the top left of the main display; the panel
        // is thousands of points away from any display in either convention.
        for screen in NSScreen.screens {
            #expect(!frame.intersects(screen.frame))
        }
        controller.send(.userClosed)
    }

    @Test func holdingKeepsResultStatesOpenAndTakesKey() async throws {
        let controller = makeController()
        controller.holdsState = true
        controller.send(.show(touch()))
        #expect(controller.panel.allowsKey)
        #expect(controller.panel.ignoresMouseEvents)

        controller.send(.show(.success(.sign)))
        try await Task.sleep(for: .seconds(TouchTiming.successHold + 0.3))
        #expect(controller.machine.state == .success(.sign))
        #expect(controller.isPanelVisible)
        #expect(controller.panel.allowsKey)
        controller.send(.dismiss)
    }
}
