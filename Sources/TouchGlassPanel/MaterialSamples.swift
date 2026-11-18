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
        /// The glass's own `tintColor`, warm neutral following the appearance, at this opacity.
        case tint(Double)
        /// The glass's own `tintColor`, a warm near-black in both appearances, at this opacity.
        case darkTint(Double)
    }

    /// How the ring, glyph and text are drawn.
    public enum Ink: Equatable {
        /// The panel's own semantic colours.
        case standard
        /// HDR white for glyph, ring and text.
        case hdrWhite
        /// HDR light blue for glyph and ring, HDR white text.
        case hdrBlue
        /// SDR pure white for glyph, ring and text.
        case white
        /// Core Animation layers with headroom-tagged colours and `preferredDynamicRange = .high`.
        case layerHDR
    }

    public struct Sample {
        public var label: String
        public var style: NSGlassEffectView.Style
        public var shading: Shading
        public var ink: Ink
        /// A wide, soft, unoffset shadow behind the glyph and text only.
        public var textShadow: Bool
        /// Opacity of a behind-window `NSVisualEffectView` under the glass, in the same window; nil for none.
        public var backdropOpacity: Double? = nil
        public var summary: String
    }

    public static let samples: [Sample] = [
        Sample(label: "C", style: .clear, shading: .darkTint(0.62), ink: .hdrWhite, textShadow: true,
               summary: "Clear glass, dark smoke tint 62%, SwiftUI exposureAdjust HDR white ink, soft shadow (did not show HDR)"),
        Sample(label: "C2", style: .clear, shading: .darkTint(0.72), ink: .white, textShadow: true,
               summary: "C with SDR pure white glyph, ring and text, and dark smoke tint 72%"),
        Sample(label: "E", style: .regular, shading: .none, ink: .hdrWhite, textShadow: true,
               summary: "Regular glass with C's ink and soft shadow"),
        Sample(label: "G2", style: .clear, shading: .darkTint(0.62), ink: .hdrWhite, textShadow: true, backdropOpacity: 0.5,
               summary: "Behind-window blur at 50% under clear glass, with C's smoke, ink and shadow"),
        Sample(label: "H", style: .clear, shading: .darkTint(0.72), ink: .layerHDR, textShadow: true,
               summary: "C2's glass with HDR white drawn by Core Animation: CAShapeLayer ring stroke, and text and glyph as layers filled with NSColor(exposure: 1) and masked by the text and symbol shape, each layer with preferredDynamicRange = .high"),
    ]

    static let size = CGSize(width: 240, height: 216)
    static let cornerRadius: CGFloat = 22
    private static var windows: [NSPanel] = []
    private static var keyMonitor: Any?

    /// Warm neutral that follows the appearance: a warm off-white in light mode, a warm
    /// near-black in dark mode, so text contrast improves in both.
    static func darkSmoke(_ opacity: Double) -> NSColor {
        NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: opacity)
    }

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

        for screen in NSScreen.screens {
            print("Screen \(screen.localizedName): EDR headroom now \(screen.maximumExtendedDynamicRangeColorComponentValue), potential \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue). HDR shows only when it is above 1.0.")
        }
        print("Click a sample before judging it. The glass only lenses in the window you clicked last; the others look flat.")
        for (index, sample) in samples.enumerated() {
            let number = index + 1
            print("\(sample.label): \(sample.summary)")
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
            // Diagnostics only: activate so the chosen sample reliably becomes key.
            NSApp.activate(ignoringOtherApps: true)
            windows[key - 1].makeKey()
        } else {
            windows.first?.makeKey()
        }
        if env["TOUCHGLASS_DUMP_LAYERS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for (index, window) in windows.enumerated() {
                    print("\(samples[index].label): key=\(window.isKeyWindow) \(glassFilterSummary(window.contentView?.layer))")
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
        switch sample.shading {
        case .none: glass.tintColor = nil
        case .tint(let opacity): glass.tintColor = smoke(opacity)
        case .darkTint(let opacity): glass.tintColor = darkSmoke(opacity)
        }
        if sample.ink == .layerHDR {
            glass.contentView = HDRLayerSampleView(frame: NSRect(origin: .zero, size: size), label: sample.label)
        } else {
            let host = DraggableHostingView(rootView: SampleContent(label: sample.label, ink: sample.ink, textShadow: sample.textShadow))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            glass.contentView = host
        }

        if let opacity = sample.backdropOpacity {
            // The blur sits under the glass in the same window, so the glass refracts the blurred image.
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = roundedMask(size: size, radius: cornerRadius)
            blur.alphaValue = opacity
            root.addSubview(blur)
            root.addSubview(glass)
            window.contentView = root
        } else {
            window.contentView = glass
        }
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

/// The touch-step content at a fixed moment, with the sample's label.
private struct SampleContent: View {
    let label: String
    let ink: MaterialSamples.Ink
    let textShadow: Bool

    private static let now = Date()
    private static let wait = TouchWait(
        operation: .sign,
        cardSerial: "12345678",
        deadline: now.addingTimeInterval(10.5),
        shownAt: now.addingTimeInterval(-4.5)
    )

    /// HDR white: SDR white pushed one stop (2x linear) above SDR peak white.
    private static let hdrWhite = Color.white.exposureAdjust(1)
    private static let hdrBlue = Color(red: 0.62, green: 0.82, blue: 1.0).exposureAdjust(1)

    private var textColor: Color { ink == .white ? .white : Self.hdrWhite }

    var body: some View {
        VStack(spacing: 12) {
            ring
                .scaleEffect(0.8)
                .frame(height: 80)
                .modifier(SoftShadow(enabled: textShadow))
            text
                .modifier(SoftShadow(enabled: textShadow))
        }
        .padding(.horizontal, 16)
        .frame(width: MaterialSamples.size.width, height: MaterialSamples.size.height)
        // Lets the HDR colours render above SDR white on a display with headroom.
        .allowedDynamicRange(.high)
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
            Text(verbatim: label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var ring: some View {
        switch ink {
        case .standard:
            TouchRingStage(wait: Self.wait, completed: false, now: Self.now)
        case .hdrWhite, .hdrBlue, .white, .layerHDR:
            let accent = ink == .hdrBlue ? Self.hdrBlue : textColor
            let diameter = PanelMetrics.ringDiameter - PanelMetrics.ringStroke
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: PanelMetrics.ringStroke)
                    .frame(width: diameter, height: diameter)
                Circle()
                    .trim(from: 0, to: Self.wait.fractionRemaining(at: Self.now))
                    .stroke(accent, style: StrokeStyle(lineWidth: PanelMetrics.ringStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: PanelMetrics.ringGlyphSize))
                    .foregroundStyle(accent)
            }
            .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)
        }
    }

    @ViewBuilder
    private var text: some View {
        switch ink {
        case .standard:
            TextBlock(presentation: PanelPresentation(.touchWait(Self.wait)))
        case .hdrWhite, .hdrBlue, .white, .layerHDR:
            let presentation = PanelPresentation(.touchWait(Self.wait))
            VStack(spacing: 4) {
                Text(verbatim: presentation.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(textColor)
                Text(verbatim: presentation.detail ?? "")
                    .font(.body)
                    .foregroundStyle(textColor.opacity(0.78))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
        }
    }
}

/// A light, wide, unoffset smoky shadow behind glyphs and text, for contrast over busy content.
private struct SoftShadow: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: Color(white: 0.1).opacity(0.35), radius: 14, x: 0, y: 0)
        } else {
            content
        }
    }
}


/// Sample H: the touch-step content drawn with Core Animation layers so that HDR colours can
/// exceed SDR white. `preferredDynamicRange` applies only to a layer's own CGColors and contents,
/// so every coloured layer sets it. Text and the symbol are not drawn in colour: a layer filled
/// with the HDR colour is masked by them, because a text or image bitmap would be SDR.
private final class HDRLayerSampleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isFlipped: Bool { true }

    init(frame: NSRect, label: String) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.isGeometryFlipped = true

        let white = NSColor(red: 1, green: 1, blue: 1, alpha: 1, exposure: 1).cgColor
        let dimWhite = NSColor(red: 1, green: 1, blue: 1, alpha: 0.8, exposure: 1).cgColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // Ring: 76.8 pt to match the other samples' 0.8 scale of the 96 pt ring.
        let ringDiameter: CGFloat = 76.8 - 3.2
        let ringFrame = CGRect(x: (frame.width - ringDiameter) / 2, y: 22, width: ringDiameter, height: ringDiameter)
        let track = CAShapeLayer()
        track.path = CGPath(ellipseIn: ringFrame, transform: nil)
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        track.lineWidth = 3.2
        root.addSublayer(track)

        let progress = CAShapeLayer()
        let center = CGPoint(x: ringFrame.midX, y: ringFrame.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: ringDiameter / 2, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * 0.7, clockwise: false)
        progress.path = path
        progress.fillColor = nil
        progress.strokeColor = white
        progress.lineWidth = 3.2
        progress.lineCap = .round
        progress.preferredDynamicRange = .high
        root.addSublayer(progress)

        // Glyph: an HDR-filled layer masked by the symbol.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 28.8, weight: .regular)
        if let symbol = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
            let glyph = CALayer()
            glyph.frame = CGRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height)
            glyph.backgroundColor = white
            glyph.preferredDynamicRange = .high
            let mask = CALayer()
            mask.frame = glyph.bounds
            mask.contents = symbol
            mask.contentsGravity = .resizeAspect
            mask.contentsScale = scale
            glyph.mask = mask
            root.addSublayer(glyph)
        }

        func textLayer(_ text: String, font: NSFont, color: CGColor, y: CGFloat) -> CALayer {
            let height = ceil(font.ascender - font.descender + font.leading) + 2
            let fill = CALayer()
            fill.frame = CGRect(x: 8, y: y, width: frame.width - 16, height: height)
            fill.backgroundColor = color
            fill.preferredDynamicRange = .high
            let mask = CATextLayer()
            mask.frame = fill.bounds
            mask.string = text
            mask.font = font
            mask.fontSize = font.pointSize
            mask.alignmentMode = .center
            mask.foregroundColor = NSColor.black.cgColor
            mask.contentsScale = scale
            fill.mask = mask
            return fill
        }

        let presentation = PanelPresentation(.touchWait(TouchWait.detected(operation: .sign, cardSerial: "12345678")))
        let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let title = textLayer(presentation.title, font: titleFont, color: white, y: 116)
        let detail = textLayer(presentation.detail ?? "", font: .systemFont(ofSize: 13), color: dimWhite, y: 142)
        for text in [title, detail] {
            text.shadowColor = NSColor(white: 0.1, alpha: 1).cgColor
            text.shadowOpacity = 0.35
            text.shadowRadius = 14
            text.shadowOffset = .zero
            root.addSublayer(text)
        }

        let labelLayer = CATextLayer()
        labelLayer.string = label
        labelLayer.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        labelLayer.fontSize = 15
        labelLayer.alignmentMode = .right
        labelLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        labelLayer.contentsScale = scale
        labelLayer.frame = CGRect(x: frame.width - 60, y: 10, width: 46, height: 20)
        root.addSublayer(labelLayer)
    }

    required init?(coder: NSCoder) { nil }
}
