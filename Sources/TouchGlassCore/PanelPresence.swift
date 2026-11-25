/// Decides what the panel controller does when the window server reports whether the panel is on screen.
///
/// After the controller orders the panel in for a visible state, it asks the window server whether the window
/// is on screen. Each failed check moves one step up the ladder: order the window in again, then replace the
/// window, then give up until `reset()`, so a window that never reaches the screen can't cause a loop.
public struct PanelPresence: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// The panel is where it should be, or there is nothing to do.
        case none
        /// Order the window out and in again, then check again.
        case reorder
        /// Replace the window with a new one, then check again.
        case rebuild
        /// Stop checking until `reset()`.
        case giveUp
    }

    /// Failed checks in a row since the last success or reset.
    public private(set) var failures = 0
    /// The ladder ran out. Checks return `.none` until `reset()`.
    public private(set) var gaveUp = false

    public init() {}

    /// `expectedOnScreen`: the controller ordered the window in for a visible state. `onScreen`: the
    /// window server lists the window as on screen.
    public mutating func check(expectedOnScreen: Bool, onScreen: Bool) -> Action {
        guard expectedOnScreen, !gaveUp else { return .none }
        if onScreen {
            failures = 0
            return .none
        }
        failures += 1
        switch failures {
        case 1: return .reorder
        case 2: return .rebuild
        default:
            gaveUp = true
            return .giveUp
        }
    }

    /// Starts the ladder over: on a new prompt, after the panel closes, and on a Space change.
    public mutating func reset() {
        failures = 0
        gaveUp = false
    }
}
