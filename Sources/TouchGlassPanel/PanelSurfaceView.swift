import SwiftUI
import TouchGlassCore

/// The window's root view: a fixed-size transparent canvas holding the glass panel.
///
/// The content is the glass view's own content, so it always renders on top of the glass and
/// stays sharp. (Inside a `GlassEffectContainer`, glass is lifted above sibling views, so the
/// content must not be a sibling.) The surface is inserted with the system `materialize` glass
/// transition and a centre-anchored scale; the content's opacity and a small centre-anchored
/// scale animate separately, after the glass on the way in and before it on the way out.
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
                    PanelContentView(model: model, state: state)
                        .opacity(model.contentShown ? 1 : 0)
                        .scaleEffect(model.contentShown || reduceMotion ? 1 : 0.96, anchor: .center)
                        .allowsHitTesting(model.contentShown)
                        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
                        .modifier(SurfaceMaterial(shape: shape, opaque: reduceTransparency, reduceMotion: reduceMotion, increasedContrast: contrast == .increased))
                        .transition(surfaceTransition)
                }
            }
            .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        }
        .frame(width: PanelMetrics.windowSize.width, height: PanelMetrics.windowSize.height)
    }

    private var surfaceTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.94, anchor: .center).combined(with: .opacity)
        )
    }
}

/// Liquid Glass behind the content, or an opaque window-coloured surface when Reduce
/// Transparency is on. Nothing else: no blur, tint or shadow of our own.
private struct SurfaceMaterial: ViewModifier {
    let shape: RoundedRectangle
    let opaque: Bool
    let reduceMotion: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: increasedContrast ? 1 : 0.5))
        } else {
            content
                .glassEffect(.regular, in: shape)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                .overlay {
                    if increasedContrast {
                        shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                }
        }
    }
}
