import SwiftUI
import TouchGlassCore

/// The window's root view: a fixed-size transparent canvas holding the glass panel.
///
/// The glass and the content are separate layers. The glass is inserted and removed inside a
/// `GlassEffectContainer` with the system `materialize` glass transition and a centre-anchored
/// scale. The content is laid out once, with animations off, and only its opacity and a small
/// centre-anchored scale animate, so nothing on the panel moves.
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
                if model.surfaceShown {
                    surface
                        .transition(surfaceTransition)
                }
                if let state = model.state {
                    PanelContentView(model: model, state: state)
                        .opacity(model.contentShown ? 1 : 0)
                        .scaleEffect(model.contentShown || reduceMotion ? 1 : 0.96, anchor: .center)
                        .allowsHitTesting(model.contentShown)
                }
            }
            .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        }
        .frame(width: PanelMetrics.windowSize.width, height: PanelMetrics.windowSize.height)
    }

    /// Liquid Glass alone, or an opaque window-coloured surface when Reduce Transparency is on.
    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            shape
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1 : 0.5))
                .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        } else {
            Color.clear
                .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
                .glassEffect(.regular, in: shape)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                }
        }
    }

    private var surfaceTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.94, anchor: .center).combined(with: .opacity)
        )
    }
}
