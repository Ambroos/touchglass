import AppKit
import SwiftUI
import TouchGlassCore
import enum TouchGlassIPC.LogEvent
import enum TouchGlassIPC.PanelKeyReason
import enum TouchGlassIPC.PanelRebuildReason
import enum TouchGlassIPC.PanelStateName
import struct TouchGlassIPC.TouchGlassLog

/// Owns the panel window and performs the effects of `PanelMachine`.
///
/// Feed it `PanelEvent`s with `send(_:)`; read user actions through `actions`.
@MainActor
public final class PanelController {
    public let model: PanelModel
    public private(set) var machine = PanelMachine()

    /// User actions from the panel. `hide` and `dismiss` are handled here first.
    public var actions = PanelActions()

    /// Internal so that tests can inspect the window. `rebuildWindow(reason:)` replaces it.
    private(set) var panel: PanelWindow
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

    /// Whether the window server shows the window. Tests replace it to stand for a window that it doesn't show.
    var onScreenProbe: (NSWindow) -> Bool = { ($0 as? PanelWindow)?.isOnScreenPerWindowServer ?? true }
    /// How long after ordering the panel in the controller asks the window server whether it is on screen.
    var presenceCheckDelay: TimeInterval = 0.25
    private var presence = PanelPresence()
    /// The one pending presence check. Each order-in and system event replaces it, so a burst of them, such as
    /// the wake notifications that arrive together, leads to one check after the last of them.
    private var presenceCheck: DispatchWorkItem?
    /// The pending new window after a wake while no state is shown, replaced in the same way.
    private var wakeRebuild: DispatchWorkItem?
    /// A wake arrived while a state showed or the exit animation ran: the next close that finishes gets a new
    /// window. It survives a close that a new state reverses.
    private var rebuildAfterClose = false
    /// Finishes a close if the exit animation's completion doesn't arrive.
    private var closeWatchdog: DispatchWorkItem?
    /// Tests only: drop the exit animation's completion, so that only the close watchdog can finish a close.
    var dropsAnimationCompletions = false
    private var systemObservers: [NSObjectProtocol] = []

    public convenience init(animationScale: Double = 1, settings: HostSettings = HostSettings()) {
        self.init(
            animationScale: animationScale,
            settings: settings,
            workspaceCenter: NSWorkspace.shared.notificationCenter,
            appCenter: NotificationCenter.default
        )
    }

    /// Tests pass their own notification centers, to post wake and screen notifications.
    init(animationScale: Double, settings: HostSettings, workspaceCenter: NotificationCenter, appCenter: NotificationCenter) {
        let model = PanelModel()
        model.animationScale = animationScale
        model.appearance = settings.appearance
        model.showsClient = settings.showClient
        self.model = model
        panel = Self.makePanel(model: model)

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
        observeSystem(workspaceCenter: workspaceCenter, appCenter: appCenter)
    }

    private static func makePanel(model: PanelModel) -> PanelWindow {
        let panel = PanelWindow()
        let host = NSHostingView(rootView: PanelSurfaceView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: PanelMetrics.windowSize)
        panel.contentView = host
        return panel
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
        schedulePresenceCheck()
    }

    // MARK: Entrance and exit

    private func open(_ state: PanelState) {
        generation += 1
        presence.reset()
        closeWatchdog?.cancel()
        closeWatchdog = nil

        if closing, panel.isVisible {
            reverseClose(into: state)
            return
        }
        // The closing window is no longer visible, so there is nothing to reverse: the close ends here, and the
        // state enters afresh.
        closing = false
        enter(state, allowsKey: state.allowsKey || holdsState)
    }

    /// Orders the panel in with `state` and runs the entrance, for the current generation.
    private func enter(_ state: PanelState, allowsKey: Bool) {
        let current = generation
        let scale = model.animationScale

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

        place()
        panel.allowsKey = allowsKey
        entrancePending = true
        panel.orderFrontRegardless()
        schedulePresenceCheck()

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

    private func place() {
        if let testOrigin {
            panel.setFrameOrigin(testOrigin)
        } else if let screen = Placement.targetScreen() {
            panel.setFrameOrigin(Placement.origin(on: screen))
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
        // AppKit reports the window as visible; order it in anyway in case the window server dropped it.
        panel.orderFrontRegardless()
        schedulePresenceCheck()
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
        // Whichever comes first, the animation's completion or the watchdog, finishes the close; the other
        // finds `closing` false or a newer generation and does nothing.
        let finish = { [weak self] (byWatchdog: Bool) in
            guard let self, self.generation == current, self.closing else { return }
            self.closing = false
            self.closeWatchdog?.cancel()
            self.closeWatchdog = nil
            if byWatchdog { self.log(.panelCloseWatchdogFired(state: self.shownStateName)) }
            if self.panel.isKeyWindow { self.log(.panelOrderedOutWhileKey(state: self.shownStateName)) }
            self.panel.orderOut(nil)
            self.presence.reset()
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { self.model.state = nil }
            if self.rebuildAfterClose { self.rebuildWindow(reason: .wake) }
        }
        let animationFinished = { [weak self] in
            guard let self, !self.dropsAnimationCompletions else { return }
            finish(false)
        }

        // SwiftUI may not run the completion, for example if its animation clock stops while the window is on
        // no display. Without the watchdog, `closing` would stay set and every later prompt would turn a close
        // around that never ends, in a window that may not be on screen.
        let exitDuration = (reduceMotion ? 0.22 : 0.41) * scale
        let watchdog = DispatchWorkItem { finish(true) }
        closeWatchdog?.cancel()
        closeWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, exitDuration + 0.5 * scale), execute: watchdog)

        if reduceMotion {
            withAnimation(.easeIn(duration: 0.22 * scale), completionCriteria: .removed) {
                model.contentShown = false
                model.surfaceShown = false
            } completion: { animationFinished() }
            return
        }

        // Content leaves first, then the glass contracts and dissolves.
        withAnimation(.easeIn(duration: 0.12 * scale)) {
            model.contentShown = false
        }
        withAnimation(.spring(duration: 0.34 * scale, bounce: 0).delay(0.07 * scale), completionCriteria: .removed) {
            model.hiddenSurfaceScale = 0.94
            model.surfaceShown = false
        } completion: { animationFinished() }
    }

    // MARK: Presence

    /// Asks the window server, `presenceCheckDelay` after the last order-in or system event, whether the panel
    /// that the current generation ordered in is on screen. One check at a time: two checks in a row would
    /// climb the ladder before the window server shows the result of the first repair.
    private func schedulePresenceCheck() {
        guard !holdsState else { return }
        presenceCheck?.cancel()
        let current = generation
        let item = DispatchWorkItem { [weak self] in
            self?.presenceCheck = nil
            self?.checkPresence(generation: current)
        }
        presenceCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + presenceCheckDelay, execute: item)
    }

    /// The window server can drop a window that AppKit still takes to be ordered in; after a sleep, every
    /// prompt was then invisible and gpg-agent waited on it. Order the window in again, then replace it, then
    /// give up until the next prompt (see `PanelPresence`).
    private func checkPresence(generation current: Int) {
        guard generation == current, !holdsState else { return }
        let expected = model.state != nil && !closing
        let onScreen = expected ? onScreenProbe(panel) : true
        let action = presence.check(expectedOnScreen: expected, onScreen: onScreen)
        guard action != .none else { return }
        log(.panelNotOnScreen(
            state: shownStateName,
            attempt: presence.failures,
            isVisible: panel.isVisible,
            isKey: panel.isKeyWindow,
            occlusionVisible: panel.occlusionState.contains(.visible),
            windowNumber: panel.windowNumber
        ))
        switch action {
        case .none:
            break
        case .reorder:
            reorder()
        case .rebuild:
            rebuildWindow(reason: .notOnScreen)
        case .giveUp:
            log(.panelPresenceGaveUp(state: shownStateName))
        }
    }

    /// Orders the panel out and in again, with its level and Spaces behaviour set again, in one visual change.
    private func reorder() {
        let wasKey = panel.isKeyWindow
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.orderOut(nil)
            panel.applyPlacementAttributes()
            panel.orderFrontRegardless()
        }
        log(.panelReordered(state: shownStateName))
        if wasKey, mayHoldKey, !panel.isKeyWindow { takeKey(.reorder) }
        schedulePresenceCheck()
    }

    /// Replaces the panel window with a new one that shows the same state. The state machine isn't told: what
    /// the panel shows doesn't change, only the window it shows in. Internal for tests.
    func rebuildWindow(reason: PanelRebuildReason) {
        let old = panel
        let new = Self.makePanel(model: model)
        new.allowsKey = old.allowsKey
        new.ignoresMouseEvents = old.ignoresMouseEvents
        new.alphaValue = old.alphaValue
        new.setFrameOrigin(old.frame.origin)

        // The observer watches the old window; `guardKeyAfterOwnChange` registers one for the new window.
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        keyGuardUntil = .distantPast
        closeWatchdog?.cancel()
        closeWatchdog = nil
        wakeRebuild?.cancel()
        wakeRebuild = nil
        rebuildAfterClose = false

        old.orderOut(nil)
        old.contentView = nil
        old.close()
        panel = new
        let wasClosing = closing
        closing = false
        entrancePending = false
        generation += 1
        log(.panelRebuilt(reason: reason, state: shownStateName))

        var instant = Transaction()
        instant.disablesAnimations = true
        if let state = model.state, !wasClosing {
            withTransaction(instant) {
                model.surfaceShown = false
                model.contentShown = false
            }
            enter(state, allowsKey: new.allowsKey)
        } else {
            withTransaction(instant) {
                model.surfaceShown = false
                model.contentShown = false
                model.state = nil
            }
        }
    }

    // MARK: Wake and screens

    private func observeSystem(workspaceCenter: NotificationCenter, appCenter: NotificationCenter) {
        let observed: [(NotificationCenter, Notification.Name, LogEvent)] = [
            (workspaceCenter, NSWorkspace.didWakeNotification, .systemWoke),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification, .screensWoke),
            (appCenter, NSApplication.didChangeScreenParametersNotification, .screenParametersChanged),
        ]
        for (center, name, event) in observed {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemChanged(event) }
            }
            systemObservers.append(token)
        }
    }

    /// After a wake, a panel that waits for the next prompt gets a new window, made after the wake. A panel that
    /// shows a state, such as a touch wait across the sleep, is placed again and checked, and gets the new window
    /// when that state closes; so does a closing panel. The check and the new window wait for
    /// `presenceCheckDelay` after the last event, because the wake and screen notifications arrive in bursts.
    private func systemChanged(_ event: LogEvent) {
        log(event)
        guard !holdsState else { return }
        let shown = model.state != nil && !closing
        switch event {
        case .systemWoke, .screensWoke:
            if shown {
                place()
                schedulePresenceCheck()
                rebuildAfterClose = true
            } else if closing {
                rebuildAfterClose = true
            } else {
                scheduleWakeRebuild()
            }
        default:
            if shown { schedulePresenceCheck() }
        }
    }

    private func scheduleWakeRebuild() {
        wakeRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeRebuild = nil
            // A prompt that opened meanwhile has its own presence check, and gets the new window when it closes.
            if self.model.state == nil, !self.closing {
                self.rebuildWindow(reason: .wake)
            } else {
                self.rebuildAfterClose = true
            }
        }
        wakeRebuild = item
        DispatchQueue.main.asyncAfter(deadline: .now() + presenceCheckDelay, execute: item)
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
