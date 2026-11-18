import Foundation

/// Timing constants for the touch step, kept in one place.
public enum TouchTiming {
    /// How long the card waits for a touch.
    public static let cardTimeout: TimeInterval = 15
    /// How long a card command must stay silent before the host assumes it waits for a touch.
    public static let detectionThreshold: TimeInterval = 0.4
    /// How long the success state shows before the panel closes.
    public static let successHold: TimeInterval = 0.7
    /// How long an error state shows before the panel closes by itself.
    public static let errorHold: TimeInterval = 4
}

/// The three escalation phases of the touch step.
public enum EscalationPhase: Int, Sendable, Comparable, CaseIterable {
    case calm = 1
    case reminder = 2
    case urgent = 3

    /// Seconds after the panel appears at which each phase starts.
    public var startsAt: TimeInterval {
        switch self {
        case .calm: 0
        case .reminder: 5
        case .urgent: 10
        }
    }

    /// Seconds between ripples.
    public var rippleInterval: TimeInterval {
        switch self {
        case .calm: 2.4
        case .reminder: 1.6
        case .urgent: 1.0
        }
    }

    public static func at(elapsed: TimeInterval) -> EscalationPhase {
        if elapsed >= EscalationPhase.urgent.startsAt { return .urgent }
        if elapsed >= EscalationPhase.reminder.startsAt { return .reminder }
        return .calm
    }

    public static func < (lhs: EscalationPhase, rhs: EscalationPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SoundCue: Sendable, Equatable {
    /// Touch step starts.
    case touchStart
    /// Reminder during the touch step.
    case reminder
    /// Timeout or other failure.
    case failure
    /// Wrong PIN or passphrase: the user's own alert sound.
    case rejected
}

/// Something the touch step does at a fixed time after the panel appears.
public struct EscalationCue: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case sound(SoundCue)
        case announceTimeLeft
    }

    public var at: TimeInterval
    public var action: Action
}

public enum Escalation {
    /// Cues after entry. The Tink at 0 s is part of entering the state, not listed here.
    public static let cues: [EscalationCue] = [
        EscalationCue(at: 5, action: .sound(.reminder)),
        EscalationCue(at: 10, action: .sound(.reminder)),
        EscalationCue(at: 10, action: .announceTimeLeft),
        EscalationCue(at: 12.5, action: .sound(.reminder)),
    ]

    /// Ripple progress at `elapsed`: `nil` between ripples, otherwise 0...1 through one ripple.
    public static func rippleProgress(elapsed: TimeInterval, duration: TimeInterval = 1.2) -> Double? {
        guard elapsed >= 0 else { return nil }
        let phase = EscalationPhase.at(elapsed: elapsed)
        let sincePhase = elapsed - phase.startsAt
        let t = sincePhase.truncatingRemainder(dividingBy: phase.rippleInterval) / duration
        return t < 1 ? t : nil
    }
}
