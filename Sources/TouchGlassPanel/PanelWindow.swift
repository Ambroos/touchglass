import AppKit

/// A borderless, non-activating floating panel. It takes key status only when `allowsKey` is set,
/// so the frontmost app stays active while the user types a PIN.
final class PanelWindow: NSPanel {
    var allowsKey = false
    /// Tests set this unless focus tests are on, so a test run never takes the keyboard from the
    /// frontmost app, where someone may be typing.
    static var refusesKey = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Setting `isFloatingPanel` sets the level to `.floating`, so it comes before the level.
        isFloatingPanel = true
        applyPlacementAttributes()
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge and depth. A window-server shadow is computed from the
        // window's alpha at order-in, while the window is still empty, so it would not match.
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // The entrance and exit are SwiftUI glass transitions inside the fixed-size window.
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    /// Above other apps' floating windows, so nothing covers a prompt.
    static let panelLevel: NSWindow.Level = .statusBar
    static let panelCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    /// Sets the level and the Spaces behaviour. The presence check sets them again before it re-orders the window.
    func applyPlacementAttributes() {
        level = Self.panelLevel
        collectionBehavior = Self.panelCollectionBehavior
    }

    /// Whether the window server lists the window as on screen: ordered in, on the current Space. Being
    /// covered by other windows or transparent doesn't count against it. Needs no Screen Recording permission.
    var isOnScreenPerWindowServer: Bool {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber })
        else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    override var canBecomeKey: Bool { allowsKey && !Self.refusesKey }
    override var canBecomeMain: Bool { false }

    /// The host has no main menu, so standard edit shortcuts have nothing to dispatch them.
    /// Send them down the responder chain from here instead. A secure field's editor refuses
    /// copy and cut itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.editAction(for: event), let responder = firstResponder, responder.tryToPerform(action, with: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The standard edit selector for Cmd-Z, Shift-Cmd-Z, Cmd-X, Cmd-C, Cmd-V and Cmd-A.
    static func editAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (modifiers, key) {
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }
}
