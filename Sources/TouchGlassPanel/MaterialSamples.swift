import AppKit
import SwiftUI
import TouchGlassCore

/// Sample panels for choosing the panel material. Each sample is its own borderless window, so
/// each one refracts or blurs the real content behind it. Drag a sample by its background.
@MainActor
public enum MaterialSamples {
    public enum Material: CaseIterable {
        case appKitRegular
        case appKitClear
        case appKitRegularTinted
        case swiftUIRegular
        case swiftUIClear
        case swiftUIRegularInteractive
        case visualEffectHUD
        case visualEffectPopover

        public var summary: String {
            switch self {
            case .appKitRegular: "NSGlassEffectView, style .regular, no tint"
            case .appKitClear: "NSGlassEffectView, style .clear, no tint"
            case .appKitRegularTinted: "NSGlassEffectView, style .regular, accent tint at 8% (reference only)"
            case .swiftUIRegular: "SwiftUI glassEffect(.regular)"
            case .swiftUIClear: "SwiftUI glassEffect(.clear)"
            case .swiftUIRegularInteractive: "SwiftUI glassEffect(.regular.interactive())"
            case .visualEffectHUD: "NSVisualEffectView, material .hudWindow (pre-Liquid Glass baseline)"
            case .visualEffectPopover: "NSVisualEffectView, material .popover (pre-Liquid Glass baseline)"
            }
        }
    }

    static let size = CGSize(width: 240, height: 216)
    static let cornerRadius: CGFloat = 22
    private static var windows: [NSPanel] = []
    private static var keyMonitor: Any?

    /// Opens one window per material, in a grid around the centre of the main screen, and
    /// prints which number is which. Esc or a close button quits.
    public static func show() {
        let materials = Material.allCases
        let columns = 4
        let rows = (materials.count + columns - 1) / columns
        let gap: CGFloat = 24
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gridWidth = CGFloat(columns) * size.width + CGFloat(columns - 1) * gap
        let gridHeight = CGFloat(rows) * size.height + CGFloat(rows - 1) * gap
        let left = (screen.midX - gridWidth / 2).rounded()
        let top = (screen.midY + gridHeight / 2).rounded()

        for (index, material) in materials.enumerated() {
            let number = index + 1
            print("\(number): \(material.summary)")
            let column = index % columns
            let row = index / columns
            let origin = NSPoint(
                x: left + CGFloat(column) * (size.width + gap),
                y: top - CGFloat(row + 1) * size.height - CGFloat(row) * gap
            )
            let window = makeWindow(material: material, number: number)
            window.setFrameOrigin(origin)
            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApp.terminate(nil) }
            return event
        }
    }

    private static func makeWindow(material: Material, number: Int) -> NSPanel {
        let window = SampleWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = SampleContent(number: number, glass: swiftUIGlass(material))
        let host = DraggableHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)

        switch material {
        case .appKitRegular, .appKitClear, .appKitRegularTinted:
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.style = material == .appKitClear ? .clear : .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = material == .appKitRegularTinted ? NSColor.controlAccentColor.withAlphaComponent(0.08) : nil
            glass.contentView = host
            window.contentView = glass
        case .visualEffectHUD, .visualEffectPopover:
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = material == .visualEffectHUD ? .hudWindow : .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = roundedMask(size: size, radius: cornerRadius)
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            window.contentView = effect
        case .swiftUIRegular, .swiftUIClear, .swiftUIRegularInteractive:
            window.contentView = host
        }
        return window
    }

    private static func swiftUIGlass(_ material: Material) -> Glass? {
        switch material {
        case .swiftUIRegular: .regular
        case .swiftUIClear: .clear
        case .swiftUIRegularInteractive: .regular.interactive()
        default: nil
        }
    }

    private static func roundedMask(size: CGSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class SampleWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets a drag on the SwiftUI content move the borderless window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The touch-step content at a fixed moment, with the sample's number.
private struct SampleContent: View {
    let number: Int
    let glass: Glass?

    private static let now = Date()
    private static let wait = TouchWait(
        operation: .sign,
        cardSerial: "12345678",
        deadline: now.addingTimeInterval(10.5),
        shownAt: now.addingTimeInterval(-4.5)
    )

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MaterialSamples.cornerRadius, style: .continuous)
        let content = VStack(spacing: 12) {
            TouchRingStage(wait: Self.wait, completed: false, now: Self.now)
                .scaleEffect(0.8)
                .frame(height: 80)
            TextBlock(presentation: PanelPresentation(.touchWait(Self.wait)))
        }
        .padding(.horizontal, 16)
        .frame(width: MaterialSamples.size.width, height: MaterialSamples.size.height)
        .overlay(alignment: .topLeading) {
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Quit"))
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: "\(number)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.trailing, 14)
        }

        if let glass {
            content.glassEffect(glass, in: shape)
        } else {
            content
        }
    }
}
