import AppKit
import SwiftUI
import TouchGlassCore

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
    /// Incremented on every entrance and exit, so a stale exit completion cannot order out a re-opened panel.
    private var generation = 0
    private var autoClose: DispatchWorkItem?
    private var escalation: [DispatchWorkItem] = []

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
            self?.send(.dismiss)
            self?.actions.dismiss()
        }
        model.actions = forwarded
    }

    public var isPanelKey: Bool { panel.isKeyWindow }
    public var isPanelVisible: Bool { panel.isVisible }
    /// The class name of the panel's first responder, for focus diagnostics.
    public var firstResponderDescription: String {
        panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }

    public func send(_ event: PanelEvent) {
        for effect in machine.handle(event) {
            perform(effect)
        }
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
        case .setKey(let allowsKey):
            panel.allowsKey = allowsKey
            if allowsKey, panel.isVisible {
                panel.makeKey()
                guardKeyAfterOwnChange()
            } else if !allowsKey, panel.isKeyWindow {
                releaseKey()
            }
        case .play(let cue):
            if !muted { sounds.play(cue) }
        case .announce(let text):
            announce(text)
        case .scheduleAutoClose(let delay):
            let item = DispatchWorkItem { [weak self] in self?.send(.autoCloseFired) }
            autoClose = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        case .cancelAutoClose:
            autoClose?.cancel()
            autoClose = nil
        case .startEscalation(let wait):
            startEscalation(wait)
        case .stopEscalation:
            escalation.forEach { $0.cancel() }
            escalation = []
        }
    }

    // MARK: Key status

    /// Until this time, a resign of key status is taken to come from our own content change and is undone.
    private var keyGuardUntil = Date.distantPast
    private var resignObserver: NSObjectProtocol?

    /// Disabling the secure field for "verifying", or removing it for the touch step, takes
    /// first responder away, and AppKit then resigns the panel's key status. Re-take key status
    /// if that happens within half a second of our own change. Later resigns come from the user
    /// clicking elsewhere and are left alone.
    private func guardKeyAfterOwnChange() {
        keyGuardUntil = Date().addingTimeInterval(0.5)
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.allowsKey, self.panel.isVisible, Date() < self.keyGuardUntil else { return }
                DispatchQueue.main.async { self.panel.makeKey() }
            }
        }
    }

    /// Gives key status back to the frontmost app's window. A window that orders out resigns key, and the
    /// window server then makes the active app's key window key again; ordering the panel straight back
    /// in, now unable to become key, keeps it on screen.
    private func releaseKey() {
        keyGuardUntil = .distantPast
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: Entrance and exit

    private func open(_ state: PanelState) {
        generation += 1
        let current = generation
        let scale = model.animationScale

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            model.surfaceShown = false
            model.contentShown = false
            model.state = state
        }

        // Resolve the layout now, with animations off, so the entrance only animates opacity and scale.
        panel.contentView?.layoutSubtreeIfNeeded()

        if let screen = Placement.targetScreen() {
            panel.setFrameOrigin(Placement.origin(on: screen))
        }
        panel.allowsKey = state.allowsKey
        panel.orderFrontRegardless()
        if state.allowsKey {
            panel.makeKey()
            guardKeyAfterOwnChange()
        }

        // Let the empty, transparent window reach the screen first, so the glass visibly
        // materialises in place instead of appearing with the window.
        DispatchQueue.main.async { [self] in
            guard generation == current else { return }
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

    private func close() {
        generation += 1
        let current = generation
        let scale = model.animationScale
        let finish = { [weak self] in
            guard let self, self.generation == current else { return }
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
            model.surfaceShown = false
        } completion: { finish() }
    }

    // MARK: Escalation

    private func startEscalation(_ wait: TouchWait) {
        escalation.forEach { $0.cancel() }
        escalation = []
        let elapsed = Date().timeIntervalSince(wait.shownAt)
        // A shorter touch-timeout ends the countdown before the last cues.
        let end = wait.deadline.timeIntervalSince(wait.shownAt)
        for cue in Escalation.cues where cue.at > elapsed && cue.at < end {
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
