import AppKit

/// A borderless, non-activating floating panel. It takes key status only when `allowsKey` is set,
/// so the frontmost app stays active while the user types a PIN.
final class PanelWindow: NSPanel {
    var allowsKey = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn in SwiftUI so it can animate with the glass; a window-server
        // shadow is computed from the window's alpha and would pop in after the entrance.
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // The entrance and exit are SwiftUI glass transitions inside the fixed-size window.
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
