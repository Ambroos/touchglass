import Foundation

/// Inputs to the panel. A later IPC layer turns protocol messages into these.
public enum PanelEvent: Sendable, Equatable {
    /// Show this state, opening the panel if it is closed.
    case show(PanelState)
    /// The user pressed the close button in the touch state. The operation goes on.
    case userHid
    /// Close the panel: the operation ended, the user cancelled, or an error state was dismissed.
    /// The panel closes after `TouchTiming.closeGrace`, unless a new state arrives first.
    case dismiss
    /// The auto-close timer for a success or error state fired. Closes like `dismiss`.
    case autoCloseFired
    /// The user closed the panel: Cancel or Escape on a prompt, OK on a message, or a click on an error.
    /// The panel closes at once, without the grace: lingering would read as lag.
    case userClosed
    /// The close grace that `scheduleClose` started ran out.
    case closeGraceFired
}

/// Outputs of the panel state machine. The AppKit layer performs them.
public enum PanelEffect: Sendable, Equatable {
    /// Order the panel in with the entrance animation.
    case open(PanelState)
    /// Change the content of the visible panel in place.
    case update(PanelState)
    /// Close the panel with the exit animation.
    case close
    case setKey(Bool)
    case play(SoundCue)
    case announce(String)
    case scheduleAutoClose(after: TimeInterval)
    case cancelAutoClose
    /// Send `closeGraceFired` after this delay. The panel keeps its last state on screen meanwhile.
    case scheduleClose(after: TimeInterval)
    case cancelClose
    /// Start the reminder sounds and announcements of a touch step.
    case startEscalation(TouchWait)
    case stopEscalation
}

/// The panel's state machine. Pure: it decides what happens; `PanelController` does it.
public struct PanelMachine: Sendable {
    /// What the panel shows, or would show if the user had not hidden it. `nil` when closed.
    public private(set) var state: PanelState?
    /// The user hid the panel for the current operation.
    public private(set) var hiddenByUser = false
    /// The panel took keyboard focus for a prompt since it opened. It then keeps focus through
    /// the touch and success states that follow without a dismiss in between, as in a card PIN
    /// prompt that turns into the touch wait: the user just typed in it, so keeping it takes
    /// nothing from the frontmost app. An error state releases it, because the user's next keys,
    /// such as Up Arrow and Return to retry, belong to the terminal. So does a dismiss or the
    /// auto-close: the user's answer is in, and the panel only lingers. A touch wait that then
    /// replaces the lingering state finds focus with the frontmost app already, and a prompt
    /// takes it again. A touch-only panel never takes focus.
    public private(set) var holdsKey = false
    /// The state still on screen during the close grace, after `dismiss` or the auto-close ended it.
    /// A state that arrives meanwhile replaces it in place instead of closing and reopening the panel:
    /// the next operation's touch wait after a success, or the touch wait that the proxy reports
    /// about `TouchTiming.detectionThreshold` after a PIN prompt ended. A lingering state takes no
    /// input: the host no longer waits for an answer to it.
    public private(set) var lingering: PanelState?

    public init() {}

    public var isVisible: Bool { state != nil && !hiddenByUser }

    public mutating func handle(_ event: PanelEvent) -> [PanelEffect] {
        switch event {
        case .show(let next):
            return show(next)
        case .userHid:
            guard isVisible, case .touchWait = state else { return [] }
            hiddenByUser = true
            return [.close]
        case .dismiss, .autoCloseFired:
            guard let ended = state else { return [] }
            let wasVisible = isVisible
            let heldKey = holdsKey
            state = nil
            hiddenByUser = false
            // Focus starts over with the next state, as in a panel that opens.
            holdsKey = false
            guard wasVisible else { return [.cancelAutoClose, .stopEscalation] }
            lingering = ended
            // The frontmost app gets the keyboard back now, not after the grace and the exit animation.
            return [.cancelAutoClose, .stopEscalation] + (heldKey ? [.setKey(false)] : []) + [.scheduleClose(after: TouchTiming.closeGrace)]
        case .userClosed:
            guard state != nil || lingering != nil else { return [] }
            let onScreen = isVisible || lingering != nil
            state = nil
            lingering = nil
            hiddenByUser = false
            holdsKey = false
            return [.cancelAutoClose, .stopEscalation, .cancelClose] + (onScreen ? [.close] : [])
        case .closeGraceFired:
            guard state == nil, lingering != nil else { return [] }
            lingering = nil
            return [.close]
        }
    }

    private mutating func show(_ next: PanelState) -> [PanelEffect] {
        let previous = state
        // Only the client label changed: the state is the same, so focus, sounds and announcements stay as they are.
        let labelOnly = previous.map { $0 != next && $0.withoutClient == next.withoutClient } ?? false
        // A hidden panel was closed on screen, so a state that ends the hide opens it again.
        let wasHidden = previous != nil && hiddenByUser
        if !Self.keepsHide(from: previous, to: next) { hiddenByUser = false }
        // A state that arrives during the close grace takes the lingering one's place on screen.
        let replacesLingering = previous == nil && lingering != nil
        let opens = previous == nil || (wasHidden && !hiddenByUser)
        if opens { holdsKey = false }
        state = next
        if next.allowsKey { holdsKey = true }
        if case .failure = next { holdsKey = false }

        var effects: [PanelEffect] = [.cancelAutoClose]
        if replacesLingering {
            lingering = nil
            effects.append(.cancelClose)
        }

        if !hiddenByUser {
            effects.append(opens && !replacesLingering ? .open(next) : .update(next))
            if opens || !labelOnly { effects.append(.setKey(holdsKey)) }
        }

        switch next {
        case .touchWait(let wait):
            // A second touch wait while a success is showing re-arms the same panel and plays Tink again.
            if case .touchWait = previous {
                // Same step, new deadline: keep escalation going from the new start.
            } else {
                effects.append(.play(.touchStart))
            }
            effects.append(.startEscalation(wait))
        case .success:
            effects.append(.stopEscalation)
            effects.append(.scheduleAutoClose(after: TouchTiming.successHold))
        case .failure(let failure):
            effects.append(.stopEscalation)
            effects.append(.play(failure == .wrongPIN ? .rejected : .failure))
            effects.append(.scheduleAutoClose(after: TouchTiming.errorHold))
        case .passphrase(let request) where request.error != nil:
            if !labelOnly { effects.append(.play(.rejected)) }
        default:
            effects.append(.stopEscalation)
        }

        if previous != next, !Self.sameAnnouncement(previous, next) {
            effects.append(.announce(PanelPresentation(next).announcement))
        }
        return effects
    }

    /// A hide covers one touch wait and the result of its operation. Any other state, such as a PIN prompt or
    /// the next operation's touch wait, must show, or a prompt the pinentry waits on would stay invisible.
    private static func keepsHide(from previous: PanelState?, to next: PanelState) -> Bool {
        guard case .touchWait(let hidden) = previous else { return false }
        switch next {
        case .touchWait(let wait):
            return wait.operation == hidden.operation && wait.cardSerial == hidden.cardSerial
        case .success, .failure:
            return true
        default:
            return false
        }
    }

    /// PIN to verifying changes nothing a VoiceOver user needs to hear again.
    private static func sameAnnouncement(_ a: PanelState?, _ b: PanelState) -> Bool {
        guard let a else { return false }
        return PanelPresentation(a).announcement == PanelPresentation(b).announcement
    }
}
