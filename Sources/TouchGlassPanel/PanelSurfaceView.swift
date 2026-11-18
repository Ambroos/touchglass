import SwiftUI
import TouchGlassCore

/// The window's root view: a fixed-size transparent canvas holding the glass panel.
///
/// The entrance and exit are SwiftUI transitions inside a `GlassEffectContainer`, so the glass
/// uses the system's `materialize` glass transition while the surface springs up from 0.9 scale.
/// The content on the glass fades and unblurs slightly after the glass, and leaves before it.
public struct PanelSurfaceView: View {
    @Bindable var model: PanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: PanelModel) {
        self.model = model
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
    }

    public var body: some View {
        GlassEffectContainer {
            ZStack {
                if model.surfaceShown, let state = model.state {
                    surface(state)
                        .transition(surfaceTransition)
                }
            }
            .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        }
        .frame(width: PanelMetrics.windowSize.width, height: PanelMetrics.windowSize.height)
    }

    @ViewBuilder
    private func surface(_ state: PanelState) -> some View {
        PanelContentView(model: model, state: state)
            .opacity(model.contentShown ? 1 : 0)
            .blur(radius: model.contentShown || reduceMotion ? 0 : 4)
            .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
            .clipShape(shape)
            .modifier(SurfaceMaterial(shape: shape, opaque: reduceTransparency, reduceMotion: reduceMotion))
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .background { PanelShadow(shape: shape) }
    }

    private var surfaceTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.94).combined(with: .opacity)
        )
    }
}

/// Liquid Glass, or an opaque window-coloured surface when Reduce Transparency is on.
private struct SurfaceMaterial: ViewModifier {
    let shape: RoundedRectangle
    let opaque: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else {
            content
                .glassEffect(.regular, in: shape)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
        }
    }
}

/// A soft drop shadow outside the panel only, so it never darkens the glass itself.
/// Drawn in SwiftUI, not by the window server, so it scales and fades with the panel.
private struct PanelShadow: View {
    let shape: RoundedRectangle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.5 : 0.2
        ZStack {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(strength * 0.6), radius: 2, y: 1)
                .shadow(color: .black.opacity(strength), radius: 28, y: 14)
        }
        .padding(-0.5)
        .mask {
            OutsideShape(cornerRadius: PanelMetrics.cornerRadius)
                .fill(style: FillStyle(eoFill: true))
                .padding(-PanelMetrics.margin)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A large rectangle with the panel's rounded rectangle cut out.
private struct OutsideShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let inner = rect.insetBy(dx: PanelMetrics.margin, dy: PanelMetrics.margin)
        path.addPath(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: inner))
        return path
    }
}
