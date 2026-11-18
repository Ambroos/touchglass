import AppKit
import SwiftUI
import TouchGlassCore

/// The content on the glass: stage, text and controls, laid out for a fixed 320 × 264 pt panel.
struct PanelContentView: View {
    let model: PanelModel
    let state: PanelState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The `@State` attribute is a macro whose plugin the Command Line Tools do not ship,
    // so state is declared with the property wrapper type directly.
    private let hoverState = State(initialValue: false)
    private var hovering: Bool { hoverState.wrappedValue }

    var body: some View {
        if case .touchWait(let wait) = state {
            // The ring and countdown follow the clock, not an animation.
            if reduceMotion {
                TimelineView(.periodic(from: wait.shownAt, by: 1)) { context in
                    content(now: context.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    content(now: context.date)
                }
            }
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let presentation = PanelPresentation(state)
        let fade = Animation.easeInOut(duration: 0.2 * model.animationScale)
        let textKey = presentation.title + "\n" + (presentation.detail ?? "") + (presentation.attemptsLine ?? "")

        return VStack(spacing: 0) {
            ZStack {
                StageView(stage: presentation.stage, now: now)
                    .id(presentation.layoutGroup)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(fade, value: presentation.layoutGroup)

            ZStack {
                TextBlock(presentation: presentation)
                    .id(textKey)
                    .transition(.opacity)
            }
            .padding(.top, 16)
            .animation(fade, value: textKey)

            if presentation.controls != .none {
                ZStack {
                    ControlsView(model: model, controls: presentation.controls, now: now)
                        .id(presentation.layoutGroup)
                        .transition(.opacity)
                }
                .padding(.top, 16)
                .animation(fade, value: presentation.layoutGroup)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        .overlay(alignment: .topLeading) {
            if case .touchWait = state {
                HideButton(visible: hovering) { model.actions.hide() }
                    .padding(12)
            }
        }
        .contentShape(Rectangle())
        .onHover { hoverState.wrappedValue = $0 }
        .onTapGesture {
            if case .failure = state { model.actions.dismiss() }
        }
    }
}

// MARK: - Stage

private struct StageView: View {
    let stage: Stage
    let now: Date

    var body: some View {
        switch stage {
        case .glyph(let glyph):
            GlyphView(glyph: glyph)
                .accessibilityHidden(true)
        case .ring(let wait, let completed):
            TouchRingStage(wait: wait, completed: completed, now: now)
        }
    }
}

struct GlyphView: View {
    let glyph: Glyph

    var body: some View {
        Image(systemName: Symbols.resolve(glyph.symbol, fallback: glyph.fallback))
            .font(.system(size: glyph.pointSize))
            .symbolRenderingMode(glyph.color == .multicolor ? .multicolor : .hierarchical)
            .foregroundStyle(glyph.color.style)
            .frame(height: glyph.pointSize + 8)
    }
}

enum Symbols {
    /// The symbol if this system has it, otherwise the fallback.
    static func resolve(_ name: String, fallback: String?) -> String {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        return fallback ?? name
    }
}

extension ColorRole {
    var style: AnyShapeStyle {
        switch self {
        case .primary, .multicolor: AnyShapeStyle(.primary)
        case .accent: AnyShapeStyle(Color.accentColor)
        case .success: AnyShapeStyle(Color.green)
        case .failure: AnyShapeStyle(Color.red)
        case .warning: AnyShapeStyle(Color.orange)
        }
    }
}

/// The countdown ring with the touch glyph inside, and the ripple behind it.
private struct TouchRingStage: View {
    let wait: TouchWait?
    let completed: Bool
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let elapsed = wait.map { now.timeIntervalSince($0.shownAt) } ?? 0
        let phase = EscalationPhase.at(elapsed: elapsed)
        let progress = completed ? 1 : (wait?.fractionRemaining(at: now) ?? 0)
        let ringColor: Color = completed ? .green : (phase == .urgent ? .orange : .accentColor)
        let diameter = PanelMetrics.ringDiameter - PanelMetrics.ringStroke

        ZStack {
            if !completed, !reduceMotion, let ripple = Escalation.rippleProgress(elapsed: elapsed) {
                Circle()
                    .stroke(ringColor, lineWidth: 1.5)
                    .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)
                    .scaleEffect(1 + 0.35 * easeOut(ripple))
                    .opacity(0.5 * (1 - ripple))
                    .accessibilityHidden(true)
            }

            Circle()
                .stroke(contrast == .increased ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), lineWidth: PanelMetrics.ringStroke)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: PanelMetrics.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .animation(.easeOut(duration: 0.25), value: completed)
                .animation(.easeInOut(duration: 0.3), value: phase)

            Image(systemName: completed ? "checkmark" : Symbols.resolve("hand.tap.fill", fallback: "dot.circle.and.hand.point.up.left.fill"))
                .font(.system(size: PanelMetrics.ringGlyphSize, weight: completed ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(completed ? Color.green : ringColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : phase.rawValue)
                .animation(.easeOut(duration: 0.25), value: completed)
                .accessibilityHidden(true)
        }
        .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Time left to touch"))
        .accessibilityValue(Text(verbatim: wait.map { "\(Int($0.remaining(at: now).rounded(.up))) seconds" } ?? ""))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}

// MARK: - Text

private struct TextBlock: View {
    let presentation: PanelPresentation

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: presentation.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            // The detail slot keeps its height when empty, so the stage does not move between states.
            Text(verbatim: presentation.detail ?? " ")
                .font(.body)
                .foregroundStyle(presentation.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(presentation.detailLineLimit)
                .opacity(presentation.detail == nil ? 0 : 1)
            if let attempts = presentation.attemptsLine {
                Text(verbatim: attempts)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Controls

private struct ControlsView: View {
    let model: PanelModel
    let controls: Controls
    let now: Date

    var body: some View {
        switch controls {
        case .none:
            EmptyView()
        case .secureField(let placeholder, let minimumLength, let cancel, let submit, let busy):
            SecureEntry(model: model, placeholder: placeholder, minimumLength: minimumLength, cancelLabel: cancel, submitLabel: submit, busy: busy)
        case .countdown(let wait):
            CountdownLine(wait: wait, now: now)
        case .countdownPlaceholder:
            Text(verbatim: " ").font(.callout).hidden()
        case .confirm(let cancel, let ok):
            HStack(spacing: 8) {
                Button { model.actions.cancel() } label: { Text(verbatim: cancel).frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button { model.actions.confirm() } label: { Text(verbatim: ok).frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .acknowledge(let ok):
            Button { model.actions.confirm() } label: { Text(verbatim: ok).frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct CountdownLine: View {
    let wait: TouchWait
    let now: Date

    var body: some View {
        let urgent = EscalationPhase.at(elapsed: now.timeIntervalSince(wait.shownAt)) == .urgent
        Text(verbatim: Copy.countdown(remaining: wait.remaining(at: now)))
            .font(.callout.monospacedDigit().weight(urgent ? .medium : .regular))
            .foregroundStyle(urgent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}

/// The secure field and its buttons. The typed text stays in this view's state and leaves it
/// only through `PanelActions.submitSecret`; nothing here logs or prints it.
private struct SecureEntry: View {
    let model: PanelModel
    let placeholder: String
    let minimumLength: Int
    let cancelLabel: String
    let submitLabel: String
    let busy: Bool

    private let textState = State(initialValue: "")
    private var text: String {
        get { textState.wrappedValue }
        nonmutating set { textState.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            SecureField(text: textState.projectedValue, prompt: Text(verbatim: placeholder)) {
                Text(verbatim: placeholder)
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .disabled(busy)
            .onSubmit(submit)
            .modifier(Shake(shakes: CGFloat(model.shakeCount)))
            .animation(reduceMotion ? nil : .linear(duration: 0.4 * model.animationScale), value: model.shakeCount)
            .accessibilityLabel(Text(verbatim: placeholder))

            HStack(spacing: 8) {
                Button { model.actions.cancel() } label: {
                    Text(verbatim: cancelLabel).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button(action: submit) {
                    ZStack {
                        Text(verbatim: submitLabel).opacity(busy ? 0 : 1)
                        if busy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy || text.count < minimumLength)
            }
        }
        .controlSize(.large)
        .defaultFocus($focused, true)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.shakeCount) {
            text = ""
            focused = true
        }
    }

    private func submit() {
        guard !busy, text.count >= minimumLength else { return }
        model.actions.submitSecret(text)
    }
}

/// Three horizontal cycles of ±8 pt over one animation.
private struct Shake: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = 8 * sin(shakes * 3 * 2 * .pi)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Hide button

private struct HideButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .accessibilityLabel(Text(verbatim: "Hide"))
    }
}
