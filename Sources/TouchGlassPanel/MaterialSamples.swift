import AppKit
import SwiftUI
import TouchGlassCore

/// Sample panels for choosing the panel material. Each sample is its own borderless window, so
/// each one refracts the real content behind it. Drag a sample by its background.
///
/// The glass looks different in a key window: `.clear` glass gets edge refraction and almost no
/// blur only while its window is key. Click a sample before judging it.
@MainActor
public enum MaterialSamples {
    /// How readability is helped on top of the glass.
    public enum Shading: Equatable {
        case none
        /// The glass's own `tintColor`, warm neutral, at this opacity.
        case tint(Double)
        /// A translucent warm-neutral fill between the glass and the content.
        case fill(Double)
        /// A feathered warm-neutral fill behind the text only; the rim stays clear.
        case centreFill(Double)
        /// A feathered thin material behind the text only; the rim stays clear.
        case centreFrost
    }

    public struct Sample {
        public var style: NSGlassEffectView.Style
        public var shading: Shading
        public var summary: String
    }

    public static let samples: [Sample] = [
        Sample(style: .clear, shading: .none, summary: "Clear glass, no shading (G, the lens reference)"),
        Sample(style: .clear, shading: .tint(0.15), summary: "Clear glass, glass tint 15% warm neutral"),
        Sample(style: .clear, shading: .tint(0.3), summary: "Clear glass, glass tint 30% warm neutral"),
        Sample(style: .clear, shading: .tint(0.5), summary: "Clear glass, glass tint 50% warm neutral"),
        Sample(style: .clear, shading: .fill(0.25), summary: "Clear glass, smoke fill layer 25% under the content"),
        Sample(style: .clear, shading: .fill(0.45), summary: "Clear glass, smoke fill layer 45% under the content"),
        Sample(style: .clear, shading: .centreFill(0.5), summary: "Clear glass, feathered smoke 50% behind the text only, rim clear"),
        Sample(style: .clear, shading: .centreFrost, summary: "Clear glass, feathered thin-material frost behind the text only, rim clear"),
        Sample(style: .regular, shading: .none, summary: "Regular glass, no shading (reference)"),
    ]

    static let size = CGSize(width: 240, height: 216)
    static let cornerRadius: CGFloat = 22
    private static var windows: [NSPanel] = []
    private static var keyMonitor: Any?

    /// Warm neutral that follows the appearance: a warm off-white in light mode, a warm
    /// near-black in dark mode, so text contrast improves in both.
    static func smoke(_ opacity: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: opacity)
            }
            return NSColor(srgbRed: 0.985, green: 0.972, blue: 0.955, alpha: opacity)
        }
    }

    /// Opens one window per sample, in a grid around the centre of the main screen, and prints
    /// which number is which. Esc or a close button quits.
    public static func show() {
        let columns = 3
        let rows = (samples.count + columns - 1) / columns
        let gap: CGFloat = 24
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gridWidth = CGFloat(columns) * size.width + CGFloat(columns - 1) * gap
        let gridHeight = CGFloat(rows) * size.height + CGFloat(rows - 1) * gap
        let left = (screen.midX - gridWidth / 2).rounded()
        let top = (screen.midY + gridHeight / 2).rounded()

        print("Click a sample to make it key before judging it: the lens only shows on the key window.")
        for (index, sample) in samples.enumerated() {
            let number = index + 1
            print("\(number): \(sample.summary)")
            let column = index % columns
            let row = index / columns
            let origin = NSPoint(
                x: left + CGFloat(column) * (size.width + gap),
                y: top - CGFloat(row + 1) * size.height - CGFloat(row) * gap
            )
            let window = makeWindow(sample: sample, number: number)
            window.setFrameOrigin(origin)
            window.orderFrontRegardless()
            windows.append(window)
        }
        let env = ProcessInfo.processInfo.environment
        if let key = env["TOUCHGLASS_KEY_SAMPLE"].flatMap(Int.init), windows.indices.contains(key - 1) {
            windows[key - 1].makeKey()
        } else {
            windows.first?.makeKey()
        }
        if env["TOUCHGLASS_DUMP_LAYERS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (index, window) in windows.enumerated() {
                    print("\(index + 1): key=\(window.isKeyWindow) \(glassFilterSummary(window.contentView?.layer))")
                }
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApp.terminate(nil) }
            return event
        }
    }

    /// Outer refraction and blur of the first glass filter under `layer`, for checking the lens profile.
    private static func glassFilterSummary(_ layer: CALayer?) -> String {
        guard let layer else { return "no layer" }
        for case let filter as NSObject in layer.filters ?? [] where "\(filter.value(forKey: "name") ?? "")" == "glassBackground" {
            let refraction = filter.value(forKey: "inputOuterRefractionAmount").map { "\($0)" } ?? "?"
            let blur = filter.value(forKey: "inputBlurRadius").map { "\($0)" } ?? "?"
            return "outerRefraction=\(refraction) blur=\(blur)"
        }
        for sublayer in layer.sublayers ?? [] {
            let found = glassFilterSummary(sublayer)
            if found != "none" { return found }
        }
        return "none"
    }

    private static func makeWindow(sample: Sample, number: Int) -> NSPanel {
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

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.style = sample.style
        glass.cornerRadius = cornerRadius
        if case .tint(let opacity) = sample.shading {
            glass.tintColor = smoke(opacity)
        }
        let host = DraggableHostingView(rootView: SampleContent(number: number, shading: sample.shading))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        glass.contentView = host
        window.contentView = glass
        return window
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
    let shading: MaterialSamples.Shading

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

        content.background { shade(in: shape) }
    }
}

extension SampleContent {
    @ViewBuilder
    fileprivate func shade(in shape: RoundedRectangle) -> some View {
        // Feathered region behind the ring and text, leaving about 20 pt of rim clear.
        let feathered = RoundedRectangle(cornerRadius: 40, style: .continuous)
            .padding(22)
            .blur(radius: 14)
        switch shading {
        case .none, .tint:
            Color.clear
        case .fill(let opacity):
            shape.fill(Color(nsColor: MaterialSamples.smoke(opacity)))
        case .centreFill(let opacity):
            Rectangle()
                .fill(Color(nsColor: MaterialSamples.smoke(opacity)))
                .mask(feathered)
        case .centreFrost:
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(feathered)
        }
    }
}
