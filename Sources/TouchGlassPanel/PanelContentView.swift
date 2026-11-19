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
                    content(now: model.frozenClock ?? context.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    content(now: model.frozenClock ?? context.date)
                }
            }
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let presentation = PanelPresentation(state)
        // State changes crossfade in place. The transitions carry their own animation, and the
        // state itself changes without one, so layout never animates and nothing slides.
        let crossfade = AnyTransition.opacity.animation(.easeInOut(duration: 0.2 * model.animationScale))
        let textKey = presentation.title + "\n" + (presentation.detail ?? "") + (presentation.attemptsLine ?? "")

        // An error has no controls: its glyph, title and message form one group, centred in the panel.
        // Other states give the stage the room that the text and controls leave.
        let centred = presentation.centresContent

        return VStack(spacing: 0) {
            if centred { Spacer(minLength: 0) }

            ZStack {
                StageView(stage: presentation.stage, now: now)
                    .id(presentation.layoutGroup)
                    .transition(crossfade)
            }
            .frame(maxWidth: .infinity, maxHeight: centred ? nil : .infinity)

            ZStack {
                TextBlock(presentation: presentation, showsClient: model.showsClient, reservesDetail: !centred)
                    .id(textKey)
                    .transition(crossfade)
            }
            .padding(.top, centred ? PanelMetrics.centredStageSpacing : 16)

            if centred { Spacer(minLength: 0) }

            if presentation.controls != .none {
                ZStack {
                    ControlsView(model: model, controls: presentation.controls, now: now)
                        .id(presentation.layoutGroup)
                        .transition(crossfade)
                }
                .padding(.top, 16)
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
    @Environment(\.panelInk) private var ink

    var body: some View {
        let name = Symbols.resolve(glyph.symbol, fallback: glyph.fallback)
        Group {
            switch ink {
            case .standard:
                Image(systemName: name)
                    .font(.system(size: glyph.pointSize))
                    .symbolRenderingMode(glyph.color == .multicolor ? .multicolor : .hierarchical)
                    .foregroundStyle(glyph.color.style)
            case .hdr:
                HDRSymbol(name: name, pointSize: glyph.pointSize, color: glyph.color.hdrColor)
            }
        }
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
    /// White for neutral glyphs; colours stay recognisable at a lower exposure.
    var hdrColor: CGColor {
        switch self {
        case .primary, .accent: HDRInk.white()
        case .success: HDRInk.color(.systemGreen, exposure: HDRInk.colourExposure)
        case .failure: HDRInk.color(.systemRed, exposure: HDRInk.colourExposure)
        case .warning: HDRInk.color(.systemOrange, exposure: HDRInk.colourExposure)
        case .multicolor: HDRInk.color(.systemYellow, exposure: HDRInk.colourExposure)
        }
    }

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
struct TouchRingStage: View {
    let wait: TouchWait?
    let completed: Bool
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelInk) private var ink

    var body: some View {
        let elapsed = wait.map { now.timeIntervalSince($0.shownAt) } ?? 0
        let phase = EscalationPhase.at(elapsed: elapsed, duration: touchDuration)
        let progress = completed ? 1 : (wait?.fractionRemaining(at: now) ?? 0)

        Group {
            switch ink {
            case .standard: standard(elapsed: elapsed, phase: phase, progress: progress)
            case .hdr: hdr(elapsed: elapsed, phase: phase, progress: progress)
            }
        }
        .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Time left to touch"))
        .accessibilityValue(Text(verbatim: wait.map { "\(Int($0.remaining(at: now).rounded(.up))) seconds" } ?? ""))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var touchDuration: TimeInterval {
        wait?.duration ?? TouchTiming.cardTimeout
    }

    private var touchSymbol: String {
        Symbols.resolve("hand.tap.fill", fallback: "dot.circle.and.hand.point.up.left.fill")
    }

    /// HDR ring and glyph drawn by Core Animation.
    @ViewBuilder
    private func hdr(elapsed: TimeInterval, phase: EscalationPhase, progress: Double) -> some View {
        let role: ColorRole = completed ? .success : (phase == .urgent ? .warning : .accent)
        ZStack {
            if !completed, !reduceMotion, let ripple = Escalation.rippleProgress(elapsed: elapsed, touchDuration: touchDuration) {
                Circle()
                    .stroke(phase == .urgent ? Color.orange : Color.white, lineWidth: 1.5)
                    .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)
                    .scaleEffect(1 + 0.35 * easeOut(ripple))
                    .opacity(0.5 * (1 - ripple))
                    .accessibilityHidden(true)
            }
            HDRRing(
                progress: progress,
                color: role.hdrColor,
                trackColor: NSColor.white.withAlphaComponent(contrast == .increased ? 0.4 : 0.22).cgColor,
                lineWidth: PanelMetrics.ringStroke
            )
            .frame(width: PanelMetrics.ringDiameter, height: PanelMetrics.ringDiameter)

            ZStack {
                HDRSymbol(name: completed ? "checkmark" : touchSymbol, pointSize: PanelMetrics.ringGlyphSize, weight: completed ? .semibold : .regular, color: role.hdrColor)
                    .id(completed)
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .center)).animation(.easeOut(duration: 0.25)))
            }
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : phase.rawValue) { content, scale in
                content.scaleEffect(scale, anchor: .center)
            } keyframes: { _ in
                SpringKeyframe(1.0, duration: 0.01)
                SpringKeyframe(1.18, duration: 0.15)
                SpringKeyframe(1.0, duration: 0.35)
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func standard(elapsed: TimeInterval, phase: EscalationPhase, progress: Double) -> some View {
        let ringColor: Color = completed ? .green : (phase == .urgent ? .orange : .accentColor)
        let diameter = PanelMetrics.ringDiameter - PanelMetrics.ringStroke

        ZStack {
            if !completed, !reduceMotion, let ripple = Escalation.rippleProgress(elapsed: elapsed, touchDuration: touchDuration) {
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
    }

    private func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}

// MARK: - Text

struct TextBlock: View {
    let presentation: PanelPresentation
    var showsClient = true
    /// Keeps a line for the detail while it is empty, so the stage stays put between states with and
    /// without one. A centred group needs no such line.
    var reservesDetail = true
    @Environment(\.panelInk) private var ink

    var body: some View {
        VStack(spacing: 4) {
            switch ink {
            case .standard:
                Text(verbatim: presentation.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            case .hdr:
                HDRText(text: presentation.title, font: .systemFont(ofSize: 17, weight: .semibold), color: HDRInk.white(), minimumScaleFactor: 0.85)
            }
            if presentation.detail != nil || reservesDetail {
                Text(verbatim: presentation.detail ?? " ")
                    .font(.body)
                    .foregroundStyle(presentation.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(presentation.detailLineLimit)
                    .opacity(presentation.detail == nil ? 0 : 1)
            }
            if showsClient, presentation.reservesClientLine {
                // What asked, such as "git commit · touchglass". The line stays while the label is
                // unknown, so a label that arrives late fades in without moving anything.
                Text(verbatim: presentation.clientLine ?? " ")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(presentation.clientLine == nil ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: presentation.clientLine)
            }
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
        case .secureField(let placeholder, let minimumLength, let cancel, let submit, let busy, let prompt):
            // A new identity per prompt gives the field new, empty state.
            SecureEntry(model: model, placeholder: placeholder, minimumLength: minimumLength, cancelLabel: cancel, submitLabel: submit, busy: busy)
                .id(prompt)
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
        let urgent = EscalationPhase.at(elapsed: now.timeIntervalSince(wait.shownAt), duration: wait.duration) == .urgent
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
            DispatchQueue.main.async {
                focused = true
                // Placeholder characters for screenshots, typed after focus so they aren't selected.
                if model.sampleSecretLength > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { text = String(repeating: "x", count: model.sampleSecretLength) }
                }
            }
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
