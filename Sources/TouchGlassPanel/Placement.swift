import AppKit

enum Placement {
    /// The screen that holds the frontmost app's frontmost window, then the screen under the
    /// pointer, then the main screen.
    @MainActor
    static func targetScreen() -> NSScreen? {
        if let frame = frontmostWindowFrame() {
            let best = NSScreen.screens
                .map { ($0, $0.frame.intersection(frame)) }
                .filter { !$0.1.isNull }
                .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            if let best { return best.0 }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Window origin that centres the visible panel horizontally and leaves half as much space
    /// above it as below, like `NSWindow.center()`.
    @MainActor
    static func origin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let panel = PanelMetrics.size
        let x = visible.midX - panel.width / 2
        let gap = visible.height - panel.height
        let y = visible.minY + gap * 2 / 3
        return NSPoint(x: (x - PanelMetrics.margin).rounded(), y: (y - PanelMetrics.margin).rounded())
    }

    /// Bounds of the frontmost app's frontmost normal window, in AppKit coordinates.
    @MainActor
    private static func frontmostWindowFrame() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // Quartz window bounds have a top-left origin on the primary display.
            guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
            return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }
}
