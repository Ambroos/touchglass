import AppKit
import SwiftUI
import TouchGlassCore
import enum TouchGlassIPC.LogEvent
import enum TouchGlassIPC.PanelKeyReason
import enum TouchGlassIPC.PanelStateName
import struct TouchGlassIPC.TouchGlassLog

/// Owns the panel window and performs the effects of `PanelMachine`.
///
/// Feed it `PanelEvent`s with `send(_:)`; read user actions through `actions`.
@MainActor
public final class PanelController {
    public let model = PanelModel()
    public private(set) var machine = PanelMachine()

    /// User actions from the panel. `hide` and `dismiss` are handled here first.
    public var actions = PanelActions()

    /// Internal so that tests can inspect the window.
    let panel = PanelWindow()
    private let sounds = Sounds()
    /// Tests set this, so they make no sound.
    var muted = false
    /// Screenshots: the panel keeps each state until the process ends, takes key status in every
    /// state so the glass shows its key look, ignores the pointer so hover effects stay off, and
    /// makes no sound.
    public var holdsState = false {
        didSet { updateMouseEvents() }
    }
    /// Tests: where the panel opens instead of its place on screen. The tests put it off every screen,
    /// with alpha 0, so a test run shows nothing.
    var testOrigin: NSPoint?
    /// Incremented on every entrance and exit, so a stale exit completion cannot order out a re-opened panel.
    private var generation = 0
    private var autoClose: DispatchWorkItem?
    private var closeGrace: DispatchWorkItem?
    /// The exit animation runs. An `open` meanwhile turns it around instead of starting over.
    private var closing = false
    private var escalation: [DispatchWorkItem] = []
    /// The window is on screen but the glass has not started to appear. The panel takes no key status
    /// until it has.
    private var entrancePending = false
    /// Tests replace this to see the key status changes.
    var log: (LogEvent) -> Void = { TouchGlassLog(.host)($0) }

    public init(animationScale: Double = 1, settings: HostSettings = HostSettings()) {
        model.animationScale = animationScale
        model.appearance = settings.appearance
        model.showsClient = settings.showClient
        let host = NSHostingView(rootView: PanelSurfaceView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: PanelMetrics.windowSize)
        panel.contentView = host

        var forwarded = PanelActions()
        forwarded.submitSecret = { [weak self] secret in self?.actions.submitSecret(secret) }
        forwarded.cancel = { [weak self] in self?.actions.cancel() }
        forwarded.confirm = { [weak self] in self?.actions.confirm() }
        forwarded.hide = { [weak self] in
            self?.send(.userHid)
            self?.actions.hide()
        }
        forwarded.dismiss = { [weak self] in
            self?.send(.userClosed)
            self?.actions.dismiss()
        }
        model.actions = forwarded
    }

    public var isPanelKey: Bool { panel.isKeyWindow }
    /// The panel window, for screenshot tooling that places a backdrop behind it and finds its frame.
    public var window: NSWindow { panel }
    public var isPanelVisible: Bool { panel.isVisible }
    /// The class name of the panel's first responder, for focus diagnostics.
    public var firstResponderDescription: String {
        panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }

    public func send(_ event: PanelEvent) {
        for effect in machine.handle(event) {
            perform(effect)
        }
        updateMouseEvents()
    }

    /// A panel that lingers in the close grace or runs its exit animation shows a state that the host no
    /// longer waits on, so clicks pass through it instead of reaching buttons that do nothing.
    private func updateMouseEvents() {
        panel.ignoresMouseEvents = holdsState || machine.state == nil
    }

    /// Shakes the secure field, after a rejected passphrase.
    public func shakeField() {
        model.shakeCount += 1
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func perform(_ effect: PanelEffect) {
        switch effect {
        case .open(let state):
            open(state)
        case .update(let state):
            // No animation in this transaction: the content view's crossfade transitions carry their own.
            withTransaction(Transaction(animation: nil)) { model.state = state }
        case .close:
            close()
        case .setKey(var allowsKey):
            allowsKey = allowsKey || holdsState
            panel.allowsKey = allowsKey
            if allowsKey, panel.isVisible {
                // During the entrance, `open` takes key status once the glass starts to appear.
                guard !entrancePending, !closing else { return }
                takeKey(.setKey)
            } else if !allowsKey, panel.isKeyWindow {
                releaseKey()
            }
        case .play(let cue):
            if !muted, !holdsState { sounds.play(cue) }
        case .announce(let text):
            announce(text)
        case .scheduleAutoClose(let delay):
            guard !holdsState else { return }
            let item = DispatchWorkItem { [weak self] in self?.send(.autoCloseFired) }
            autoClose = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        case .cancelAutoClose:
            autoClose?.cancel()
            autoClose = nil
        case .scheduleClose(let delay):
            closeGrace?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.send(.closeGraceFired) }
            closeGrace = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        case .cancelClose:
            closeGrace?.cancel()
            closeGrace = nil
        case .startEscalation(let wait):
            if !holdsState { startEscalation(wait) }
        case .stopEscalation:
            escalation.forEach { $0.cancel() }
            escalation = []
        }
    }

    // MARK: Key status

    /// Until this time, a resign of key status is taken to come from our own content change and is undone.
    private var keyGuardUntil = Date.distantPast
    private var resignObserver: NSObjectProtocol?

    /// Whether the panel may have key status now: a prompt, or the states after one that keep it (see
    /// `PanelMachine.holdsKey`), is on screen, and the glass is appearing or shown. Never while hidden,
    /// lingering, closing or before the entrance starts.
    private var mayHoldKey: Bool {
        guard panel.allowsKey, panel.isVisible, !entrancePending, !closing else { return false }
        return holdsState || (machine.isVisible && machine.holdsKey)
    }

    /// Makes the panel key, logs it, and, for our own change, starts the guard against the resigns that the
    /// change causes. A re-take doesn't restart the guard: otherwise each click elsewhere within half a
    /// second of the last re-take would take the keyboard back again.
    private func takeKey(_ reason: PanelKeyReason) {
        let before = Self.frontmostApp()
        panel.makeKey()
        log(.panelKeyTaken(state: shownStateName, reason: reason, isKey: panel.isKeyWindow, frontmostBefore: before, frontmostAfter: Self.frontmostApp()))
        if reason != .retake { guardKeyAfterOwnChange() }
    }

    private static func frontmostApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var shownStateName: PanelStateName? {
        model.state.map(Self.name)
    }

    static func name(_ state: PanelState) -> PanelStateName {
        switch state {
        case .pinEntry: .pinEntry
        case .verifying: .verifying
        case .passphrase: .passphrase
        case .touchWait: .touchWait
        case .success: .success
        case .failure: .failure
        case .confirm: .confirm
        case .message: .message
        }
    }

    /// Disabling the secure field for "verifying", or removing it for the touch step, takes
    /// first responder away, and AppKit then resigns the panel's key status. Re-take key status
    /// if that happens within half a second of our own change and the panel may still hold it. Later
    /// resigns come from the user clicking elsewhere and are left alone. The check runs again when the
    /// re-take runs, because the state may change in between.
    private func guardKeyAfterOwnChange() {
        keyGuardUntil = Date().addingTimeInterval(0.5)
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date() < self.keyGuardUntil else { return }
                DispatchQueue.main.async {
                    guard Date() < self.keyGuardUntil, !self.panel.isKeyWindow else { return }
                    if self.mayHoldKey {
                        self.takeKey(.retake)
                    } else {
                        self.log(.panelKeyRetakeSkipped(state: self.shownStateName))
                    }
                }
            }
        }
    }

    /// Gives key status back to the frontmost app's window. A window that orders out resigns key, and the
    /// window server then makes the active app's key window key again; ordering the panel straight back
    /// in, now unable to become key, keeps it on screen. Both happen in one animation group, which AppKit
    /// commits as one visual change, so the panel doesn't blink while it lingers or shows an error.
    private func releaseKey() {
        keyGuardUntil = .distantPast
        let before = Self.frontmostApp()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        log(.panelKeyReleased(state: shownStateName, isKey: panel.isKeyWindow, frontmostBefore: before, frontmostAfter: Self.frontmostApp()))
    }

    // MARK: Entrance and exit

    private func open(_ state: PanelState) {
        generation += 1
        let current = generation
        let scale = model.animationScale

        if closing, panel.isVisible {
            reverseClose(into: state)
            return
        }

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            model.surfaceShown = false
            model.contentShown = false
            model.hiddenSurfaceScale = 0.9
            model.state = state
        }

        // Resolve the layout now, with animations off, so the entrance only animates opacity and scale.
        panel.contentView?.layoutSubtreeIfNeeded()

        if let testOrigin {
            panel.setFrameOrigin(testOrigin)
        } else if let screen = Placement.targetScreen() {
            panel.setFrameOrigin(Placement.origin(on: screen))
        }
        panel.allowsKey = state.allowsKey || holdsState
        entrancePending = true
        panel.orderFrontRegardless()

        // Let the empty, transparent window reach the screen first, so the glass visibly
        // materialises in place instead of appearing with the window. The panel takes key status
        // only then: an empty window that takes the keyboard reads as focus vanishing.
        DispatchQueue.main.async { [self] in
            guard generation == current else { return }
            entrancePending = false
            if mayHoldKey { takeKey(.open) }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.16 * scale)) {
                    model.surfaceShown = true
                    model.contentShown = true
                }
            } else {
                // The glass springs up from 0.9 around its centre while the system materialize
                // transition brings in its refraction; the content follows once the glass has body.
                withAnimation(.spring(duration: 0.5 * scale, bounce: 0.2)) {
                    model.surfaceShown = true
                }
                withAnimation(.easeOut(duration: 0.24 * scale).delay(0.12 * scale)) {
                    model.contentShown = true
                }
            }
        }
    }

    /// A state arrived while the exit animation runs: the panel is still on screen, at its place, so
    /// swap the content and animate the glass and content back from wherever the exit has got them.
    /// SwiftUI retargets the running animations, so the glass grows back around its centre without
    /// first vanishing. The stale exit completion sees a newer generation and does nothing.
    private func reverseClose(into state: PanelState) {
        closing = false
        let scale = model.animationScale
        withTransaction(Transaction(animation: nil)) { model.state = state }
        panel.allowsKey = state.allowsKey || holdsState
        if mayHoldKey { takeKey(.reverseClose) }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.16 * scale)) {
                model.surfaceShown = true
                model.contentShown = true
            }
        } else {
            withAnimation(.spring(duration: 0.4 * scale, bounce: 0.15)) {
                model.surfaceShown = true
            }
            withAnimation(.easeOut(duration: 0.2 * scale).delay(0.06 * scale)) {
                model.contentShown = true
            }
        }
    }

    private func close() {
        generation += 1
        let current = generation
        let scale = model.animationScale
        closing = true
        entrancePending = false
        // A closing panel takes no input, so the keyboard goes back to the frontmost app now, not after
        // the exit animation.
        if !holdsState {
            panel.allowsKey = false
            if panel.isKeyWindow { releaseKey() }
        }
        let finish = { [weak self] in
            guard let self, self.generation == current else { return }
            self.closing = false
            if self.panel.isKeyWindow { self.log(.panelOrderedOutWhileKey(state: self.shownStateName)) }
            self.panel.orderOut(nil)
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { self.model.state = nil }
        }

        if reduceMotion {
            withAnimation(.easeIn(duration: 0.22 * scale), completionCriteria: .removed) {
                model.contentShown = false
                model.surfaceShown = false
            } completion: { finish() }
            return
        }

        // Content leaves first, then the glass contracts and dissolves.
        withAnimation(.easeIn(duration: 0.12 * scale)) {
            model.contentShown = false
        }
        withAnimation(.spring(duration: 0.34 * scale, bounce: 0).delay(0.07 * scale), completionCriteria: .removed) {
            model.hiddenSurfaceScale = 0.94
            model.surfaceShown = false
        } completion: { finish() }
    }

    // MARK: Escalation

    private func startEscalation(_ wait: TouchWait) {
        escalation.forEach { $0.cancel() }
        escalation = []
        let elapsed = Date().timeIntervalSince(wait.shownAt)
        // No cue plays after the countdown ends.
        let end = wait.deadline.timeIntervalSince(wait.shownAt)
        for cue in Escalation.cues(duration: wait.duration) where cue.at > elapsed && cue.at < end {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                switch cue.action {
                case .sound(let sound):
                    if !self.muted { self.sounds.play(sound) }
                case .announceTimeLeft:
                    self.announce(Copy.timeLeftAnnouncement(remaining: wait.remaining(at: Date())))
                }
            }
            escalation.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + (cue.at - elapsed), execute: item)
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
