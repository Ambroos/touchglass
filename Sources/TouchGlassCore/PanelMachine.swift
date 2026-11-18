import Foundation

/// Inputs to the panel. A later IPC layer turns protocol messages into these.
public enum PanelEvent: Sendable, Equatable {
    /// Show this state, opening the panel if it is closed.
    case show(PanelState)
    /// The user pressed the close button in the touch state. The operation goes on.
    case userHid
    /// Close the panel: the operation ended, the user cancelled, or an error state was dismissed.
    case dismiss
    /// The auto-close timer for a success or error state fired.
    case autoCloseFired
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
    /// the touch, success and error states that follow: the user just typed in it, so keeping
    /// it takes nothing from the frontmost app. A touch-only panel never takes focus.
    public private(set) var holdsKey = false

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
            guard state != nil else { return [] }
            let wasVisible = isVisible
            state = nil
            hiddenByUser = false
            holdsKey = false
            return [.cancelAutoClose, .stopEscalation] + (wasVisible ? [.close] : [])
        }
    }

    private mutating func show(_ next: PanelState) -> [PanelEffect] {
        let previous = state
        if previous == nil {
            hiddenByUser = false
            holdsKey = false
        }
        state = next
        if next.allowsKey { holdsKey = true }

        var effects: [PanelEffect] = [.cancelAutoClose]

        if !hiddenByUser {
            effects.append(previous == nil ? .open(next) : .update(next))
            effects.append(.setKey(holdsKey))
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
            effects.append(.play(.rejected))
        default:
            effects.append(.stopEscalation)
        }

        if previous != next, !Self.sameAnnouncement(previous, next) {
            effects.append(.announce(PanelPresentation(next).announcement))
        }
        return effects
    }

    /// PIN to verifying changes nothing a VoiceOver user needs to hear again.
    private static func sameAnnouncement(_ a: PanelState?, _ b: PanelState) -> Bool {
        guard let a else { return false }
        return PanelPresentation(a).announcement == PanelPresentation(b).announcement
    }
}
