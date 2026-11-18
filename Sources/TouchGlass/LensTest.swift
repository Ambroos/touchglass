import AppKit
import SwiftUI

/// Spike: does Liquid Glass lens (warp at its edges) content behind it?
///
/// Finding: the glass filter depends on whether its window is key. In a key window the glass
/// gets outer edge refraction; with style `.clear` its blur also drops to under 1 pt, which
/// reads as a lens. A window that only claims to be key (case K) does not get this.
/// Set TOUCHGLASS_KEY_CASE=<letter> to choose which case's window is key.
///
/// Opens a high-contrast "target" window and glass windows arranged over it, plus windows where
/// the same high-contrast content sits inside the glass's own window. Compare the edges of each
/// glass: lensing bends the stripes and letters near the rim; plain blur only softens them.
@MainActor
enum LensTest {
    private static var windows: [NSWindow] = []

    struct Case {
        let letter: String
        let summary: String
    }

    static func show() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetSize = CGSize(width: 560, height: 380)
        let targetOrigin = NSPoint(x: (screen.midX - targetSize.width - 40).rounded(), y: (screen.midY - targetSize.height / 2).rounded())

        // The target: an opaque window with stripes and large black text.
        let target = makeWindow(size: targetSize, opaque: true)
        target.level = .floating
        target.contentView = NSHostingView(rootView: HighContrast().frame(width: targetSize.width, height: targetSize.height))
        target.setFrameOrigin(targetOrigin)
        target.orderFrontRegardless()
        windows.append(target)

        var cases: [(Case, NSWindow, NSPoint)] = []
        let glassSize = CGSize(width: 200, height: 140)

        // A: cross-window, AppKit glass straddling the target's right edge.
        cases.append((Case(letter: "A", summary: "Cross-window: NSGlassEffectView .regular in its own window over the target's right edge"),
                      appKitGlassWindow(size: glassSize, letter: "A", style: .regular),
                      NSPoint(x: targetOrigin.x + targetSize.width - 100, y: targetOrigin.y + 210)))
        // B: cross-window, AppKit clear glass.
        cases.append((Case(letter: "B", summary: "Cross-window: NSGlassEffectView .clear over the target's right edge"),
                      appKitGlassWindow(size: glassSize, letter: "B", style: .clear),
                      NSPoint(x: targetOrigin.x + targetSize.width - 100, y: targetOrigin.y + 30)))
        // C: cross-window, SwiftUI glass over the target's bottom edge.
        cases.append((Case(letter: "C", summary: "Cross-window: SwiftUI glassEffect(.clear) over the target's bottom edge"),
                      swiftUIGlassWindow(size: glassSize, letter: "C"),
                      NSPoint(x: targetOrigin.x + 60, y: targetOrigin.y - 70)))

        // D, E: the high-contrast content inside the glass's own window.
        let inWindowSize = CGSize(width: 320, height: 230)
        let right = targetOrigin.x + targetSize.width + 140
        cases.append((Case(letter: "D", summary: "In-window: NSGlassEffectView .clear as a sibling above stripes in the same window"),
                      appKitInWindow(size: inWindowSize, glassSize: glassSize, letter: "D"),
                      NSPoint(x: right, y: targetOrigin.y + targetSize.height - inWindowSize.height + 60)))
        cases.append((Case(letter: "E", summary: "In-window: SwiftUI glassEffect(.clear) over stripes in the same view tree"),
                      swiftUIInWindow(size: inWindowSize, glassSize: glassSize, letter: "E"),
                      NSPoint(x: right, y: targetOrigin.y - 60)))

            // K: public API only, in a window that claims to be key without taking focus.
            let k = FakeKeyPanel(contentRect: NSRect(origin: .zero, size: glassSize), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            k.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            k.isOpaque = false
            k.backgroundColor = .clear
            k.hasShadow = false
            k.isMovableByWindowBackground = true
            let glassK = NSGlassEffectView(frame: NSRect(origin: .zero, size: glassSize))
            glassK.style = .regular
            glassK.cornerRadius = 26
            glassK.contentView = MovableHostingView(rootView: Label(letter: "K"))
            k.contentView = glassK
            cases.append((Case(letter: "K", summary: "Experiment: public .regular glass in a window whose isKeyWindow returns true while it is not key"),
                          k, NSPoint(x: targetOrigin.x + 300, y: targetOrigin.y + 120)))

        for (testCase, window, origin) in cases {
            print("\(testCase.letter): \(testCase.summary)")
            window.setFrameOrigin(origin)
            window.orderFrontRegardless()
            windows.append(window)
        }
        if let letter = ProcessInfo.processInfo.environment["TOUCHGLASS_KEY_CASE"],
           let match = cases.first(where: { $0.0.letter == letter }) {
            match.1.makeKey()
        } else {
            windows.last?.makeKey()
        }

        if ProcessInfo.processInfo.environment["TOUCHGLASS_DUMP_LAYERS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (testCase, window, _) in cases {
                    print("== \(testCase.letter) layers")
                    if let layer = window.contentView?.layer { dump(layer, depth: 0) }
                }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApp.terminate(nil) }
            return event
        }
    }

    // MARK: Windows

    private static func makeWindow(size: CGSize, opaque: Bool) -> NSPanel {
        let window = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = opaque
        window.backgroundColor = opaque ? .white : .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private static func appKitGlassWindow(size: CGSize, letter: String, style: NSGlassEffectView.Style) -> NSWindow {
        let window = makeWindow(size: size, opaque: false)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.style = style
        glass.cornerRadius = 26
        glass.contentView = MovableHostingView(rootView: Label(letter: letter))
        window.contentView = glass
        return window
    }

    private static func swiftUIGlassWindow(size: CGSize, letter: String) -> NSWindow {
        let window = makeWindow(size: size, opaque: false)
        let view = Label(letter: letter)
            .frame(width: size.width, height: size.height)
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        window.contentView = MovableHostingView(rootView: view)
        return window
    }

    private static func appKitInWindow(size: CGSize, glassSize: CGSize, letter: String) -> NSWindow {
        let window = makeWindow(size: size, opaque: true)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let stripes = MovableHostingView(rootView: HighContrast().frame(width: size.width, height: size.height))
        stripes.frame = root.bounds
        root.addSubview(stripes)
        let glass = NSGlassEffectView(frame: NSRect(
            x: (size.width - glassSize.width) / 2, y: (size.height - glassSize.height) / 2,
            width: glassSize.width, height: glassSize.height
        ))
        glass.style = .clear
        glass.cornerRadius = 26
        glass.contentView = MovableHostingView(rootView: Label(letter: letter))
        root.addSubview(glass)
        window.contentView = root
        return window
    }

    private static func swiftUIInWindow(size: CGSize, glassSize: CGSize, letter: String) -> NSWindow {
        let window = makeWindow(size: size, opaque: true)
        let view = ZStack {
            HighContrast()
            Label(letter: letter)
                .frame(width: glassSize.width, height: glassSize.height)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
        window.contentView = MovableHostingView(rootView: view)
        return window
    }

    /// Prints each layer's class, and its filters and backdrop settings, for the spike.
    private static func dump(_ layer: CALayer, depth: Int) {
        guard depth < 12 else { return }
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: layer))
        if let filters = layer.filters, !filters.isEmpty {
            line += " filters=" + filters.map { ($0 as? NSObject)?.value(forKey: "name").map { "\($0)" } ?? "\($0)" }.joined(separator: ",")
        }
        if let filters = layer.backgroundFilters, !filters.isEmpty {
            line += " backgroundFilters=" + filters.map { ($0 as? NSObject)?.value(forKey: "name").map { "\($0)" } ?? "\($0)" }.joined(separator: ",")
        }
        if let filters = layer.filters {
            for case let filter as NSObject in filters where "\(filter.value(forKey: "name") ?? "")" == "glassBackground" {
                if let keys = filter.value(forKey: "inputKeys") as? [String] {
                    let values = keys.map { key in "\(key)=\(filter.value(forKey: key).map { "\($0)" } ?? "nil")" }
                    line += " [" + values.joined(separator: " ").replacingOccurrences(of: "\n", with: " ") + "]"
                }
            }
        }
        if layer.compositingFilter != nil { line += " compositingFilter=\(layer.compositingFilter!)" }
        print(line)
        for sublayer in layer.sublayers ?? [] { dump(sublayer, depth: depth + 1) }
    }
}

private final class FakeKeyPanel: NSPanel {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { false }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class MovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Diagonal black and white stripes with large black text: anything that bends shows clearly.
private struct HighContrast: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                let step: CGFloat = 16
                var x: CGFloat = -size.height
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: .color(.black), lineWidth: step / 2)
                    x += step
                }
            }
            Text(verbatim: "Aa Lens 123")
                .font(.system(size: 64, weight: .black))
                .foregroundStyle(.black)
                .background(Color.white)
        }
    }
}

private struct Label: View {
    let letter: String

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
