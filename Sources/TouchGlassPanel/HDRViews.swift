import AppKit
import SwiftUI

/// HDR drawing for the panel's title, glyphs and ring.
///
/// SwiftUI text and symbols render as SDR bitmaps, so a colour above SDR white has no effect on
/// them. These views draw with Core Animation instead: a layer filled with a headroom-tagged
/// colour (`NSColor(red:green:blue:alpha:exposure:)`), masked by the text or symbol shape, with
/// `preferredDynamicRange = .high`. That setting applies only to the layer's own colours, so
/// every coloured layer sets it. On a display without EDR headroom the colours clip to SDR.
enum HDRInk {
    /// One stop (2x linear) above SDR white.
    static let whiteExposure: CGFloat = 1
    /// Coloured glyphs get less, so they stay recognisably red, green or orange.
    static let colourExposure: CGFloat = 0.5

    static func color(_ base: NSColor, exposure: CGFloat) -> CGColor {
        let srgb = base.usingColorSpace(.sRGB) ?? base
        return NSColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent, exposure: exposure).cgColor
    }

    static func white(opacity: CGFloat = 1) -> CGColor {
        NSColor(red: 1, green: 1, blue: 1, alpha: opacity, exposure: whiteExposure).cgColor
    }
}

/// A layer-hosting view that fills its bounds with an HDR colour through a mask.
class MaskedFillView: NSView {
    let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        fill.preferredDynamicRange = .high
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.mask?.frame = bounds
        layoutMask()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        fill.contentsScale = scale
        fill.mask?.contentsScale = scale
    }

    func layoutMask() {}
}

// MARK: - Text

final class HDRTextView: MaskedFillView {
    private let textMask = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        textMask.alignmentMode = .center
        textMask.isWrapped = true
        textMask.truncationMode = .end
        textMask.foregroundColor = NSColor.black.cgColor
        fill.mask = textMask
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, font: NSFont, color: CGColor) {
        textMask.string = text
        textMask.font = font
        textMask.fontSize = font.pointSize
        fill.backgroundColor = color
    }
}

/// Text in an HDR colour. Sizes itself like a centred, wrapping `Text` with a line limit.
struct HDRText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: CGColor
    var lineLimit = 1
    /// For one line: shrink the font down to this factor before truncating.
    var minimumScaleFactor: CGFloat = 1

    func makeNSView(context: Context) -> HDRTextView {
        HDRTextView(frame: .zero)
    }

    func updateNSView(_ view: HDRTextView, context: Context) {
        view.update(text: text, font: fittedFont(width: view.bounds.width), color: color)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HDRTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        let font = fittedFont(width: width)
        nsView.update(text: text, font: font, color: color)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(ceil(measured.height), lineHeight * CGFloat(lineLimit))
        return CGSize(width: min(ceil(measured.width) + 2, width), height: max(height, lineHeight))
    }

    private func fittedFont(width: CGFloat) -> NSFont {
        guard lineLimit == 1, minimumScaleFactor < 1, width > 0 else { return font }
        let natural = NSAttributedString(string: text, attributes: [.font: font]).size().width
        guard natural > width else { return font }
        let scale = max(minimumScaleFactor, width / natural)
        return NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
    }
}

// MARK: - Symbol

final class HDRSymbolView: MaskedFillView {
    private let imageMask = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageMask.contentsGravity = .resizeAspect
        fill.mask = imageMask
    }

    required init?(coder: NSCoder) { nil }

    func update(image: NSImage?, color: CGColor) {
        imageMask.contents = image
        fill.backgroundColor = color
    }
}

/// An SF Symbol in an HDR colour.
struct HDRSymbol: NSViewRepresentable {
    let name: String
    let pointSize: CGFloat
    var weight: NSFont.Weight = .regular
    let color: CGColor

    private var image: NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    func makeNSView(context: Context) -> HDRSymbolView {
        HDRSymbolView(frame: .zero)
    }

    func updateNSView(_ view: HDRSymbolView, context: Context) {
        view.update(image: image, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HDRSymbolView, context: Context) -> CGSize? {
        image?.size ?? CGSize(width: pointSize, height: pointSize)
    }
}

// MARK: - Ring

final class HDRRingView: NSView {
    private let track = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var lineWidth: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        for shape in [track, progressLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        progressLayer.preferredDynamicRange = .high
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Progress follows the clock with no animation; the jump to full on success and colour
    /// changes animate over 0.25 s.
    func update(progress: CGFloat, color: CGColor, trackColor: CGColor, lineWidth: CGFloat) {
        let completing = progress >= 1 && progressLayer.strokeEnd < 0.999
        let recoloring = progressLayer.strokeColor.map { $0 != color } ?? false
        self.lineWidth = lineWidth
        CATransaction.begin()
        if completing || recoloring {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        track.strokeColor = trackColor
        progressLayer.strokeColor = color
        track.lineWidth = lineWidth
        progressLayer.lineWidth = lineWidth
        progressLayer.strokeEnd = min(max(progress, 0), 1)
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        track.frame = bounds
        progressLayer.frame = bounds
        if inset.width > 0 {
            track.path = CGPath(ellipseIn: inset, transform: nil)
            // A full circle from 12 o'clock, clockwise. The layer is not flipped, so clockwise
            // means decreasing angle. strokeEnd shows the remaining fraction.
            let path = CGMutablePath()
            let start = CGFloat.pi / 2
            path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2, startAngle: start, endAngle: start - 2 * .pi, clockwise: true)
            progressLayer.path = path
        }
        CATransaction.commit()
    }
}

/// The countdown ring in an HDR colour. The view fills the size SwiftUI gives it.
struct HDRRing: NSViewRepresentable {
    let progress: Double
    let color: CGColor
    let trackColor: CGColor
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> HDRRingView {
        HDRRingView(frame: .zero)
    }

    func updateNSView(_ view: HDRRingView, context: Context) {
        view.update(progress: progress, color: color, trackColor: trackColor, lineWidth: lineWidth)
    }
}

// MARK: - Ink

/// How the panel draws its title, glyphs and ring.
enum PanelInk: Sendable {
    /// System label colours and SwiftUI text, for light glass.
    case standard
    /// HDR white through Core Animation, for smoked glass.
    case hdr
}

struct PanelInkKey: EnvironmentKey {
    static let defaultValue = PanelInk.standard
}

extension EnvironmentValues {
    var panelInk: PanelInk {
        get { self[PanelInkKey.self] }
        set { self[PanelInkKey.self] = newValue }
    }
}
