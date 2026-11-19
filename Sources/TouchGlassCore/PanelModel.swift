import Foundation
import Observation

/// Callbacks from the panel's controls.
public struct PanelActions {
    /// The user submitted the secure field. The string is the secret; never log or print it.
    public var submitSecret: (String) -> Void = { _ in }
    public var cancel: () -> Void = {}
    public var confirm: () -> Void = {}
    public var hide: () -> Void = {}
    /// A click on an error state.
    public var dismiss: () -> Void = {}

    public init() {}
}

/// The view model the SwiftUI panel renders. `PanelController` owns and drives it.
@MainActor
@Observable
public final class PanelModel {
    /// The state on screen. It stays set while the exit animation runs.
    public var state: PanelState?
    /// The glass surface is present. Toggled inside an animation to materialise or dissolve it.
    public var surfaceShown = false
    /// The glass's scale while `surfaceShown` is false: where the entrance starts and the exit ends.
    public var hiddenSurfaceScale = 0.9
    /// The content on the glass is shown. Lags the surface on the way in and leads it on the way out.
    public var contentShown = false
    /// Incremented to shake the secure field after a rejected passphrase.
    public var shakeCount = 0
    /// Multiplies every panel animation duration. Demo mode uses it to slow animations down for review.
    public var animationScale: Double = 1
    /// The panel's look.
    public var appearance: PanelAppearance = .readable
    /// Show what asked for the operation under the detail, and keep a line for it.
    public var showsClient = true
    /// Screenshots only: the clock the touch ring and countdown read instead of the current time.
    public var frozenClock: Date?
    /// Screenshots only: the number of placeholder characters a secure field starts with, so it shows dots.
    public var sampleSecretLength = 0

    @ObservationIgnored public var actions = PanelActions()

    public init() {}
}
