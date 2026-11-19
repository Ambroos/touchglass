import Foundation

/// Timing constants for the touch step, kept in one place.
public enum TouchTiming {
    /// How long the card waits for a touch.
    public static let cardTimeout: TimeInterval = 15
    /// How long a card command must stay silent before the host assumes it waits for a touch.
    public static let detectionThreshold: TimeInterval = 0.4
    /// How long the success state shows before the panel closes. The ring and checkmark settle in
    /// 0.25 s, so this leaves about a second to read the result; 0.7 s closed the panel before the
    /// eye got to the title.
    public static let successHold: TimeInterval = 1.2
    /// How long the panel keeps its last state after it was dismissed or auto-closed, before the exit
    /// animation starts. A state that arrives meanwhile replaces it in place. Longer than
    /// `detectionThreshold`, after which the proxy reports the touch wait that follows a PIN prompt,
    /// plus 0.2 s for the command to reach scdaemon and the event to reach the host.
    public static let closeGrace: TimeInterval = 0.6
    /// How long an error state shows before the panel closes by itself.
    public static let errorHold: TimeInterval = 4
}

/// The three escalation phases of the touch step.
public enum EscalationPhase: Int, Sendable, Comparable, CaseIterable {
    case calm = 1
    case reminder = 2
    case urgent = 3

    /// Seconds after the panel appears at which each phase starts, for a touch timeout of `duration`
    /// seconds. With the card's 15 s, the reminder phase starts at 5 s and the urgent phase at 10 s;
    /// other timeouts keep those proportions.
    public func startsAt(duration: TimeInterval = TouchTiming.cardTimeout) -> TimeInterval {
        let seconds: TimeInterval = switch self {
        case .calm: 0
        case .reminder: 5
        case .urgent: 10
        }
        return Escalation.scaled(seconds, to: duration)
    }

    /// Seconds between ripples.
    public var rippleInterval: TimeInterval {
        switch self {
        case .calm: 2.4
        case .reminder: 1.6
        case .urgent: 1.0
        }
    }

    public static func at(elapsed: TimeInterval, duration: TimeInterval = TouchTiming.cardTimeout) -> EscalationPhase {
        if elapsed >= EscalationPhase.urgent.startsAt(duration: duration) { return .urgent }
        if elapsed >= EscalationPhase.reminder.startsAt(duration: duration) { return .reminder }
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
    /// Cues after entry, for a touch timeout of `duration` seconds. The Tink at 0 s is part of entering
    /// the state, not listed here. The times are for the card's 15 s and scale with `duration`.
    public static func cues(duration: TimeInterval = TouchTiming.cardTimeout) -> [EscalationCue] {
        [
            EscalationCue(at: scaled(5, to: duration), action: .sound(.reminder)),
            EscalationCue(at: scaled(10, to: duration), action: .sound(.reminder)),
            EscalationCue(at: scaled(10, to: duration), action: .announceTimeLeft),
            EscalationCue(at: scaled(12.5, to: duration), action: .sound(.reminder)),
        ]
    }

    /// `seconds` of the card's 15 s timeout, scaled to a timeout of `duration`.
    static func scaled(_ seconds: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        seconds * duration / TouchTiming.cardTimeout
    }

    /// Ripple progress at `elapsed`: `nil` between ripples, otherwise 0...1 through one ripple.
    /// `touchDuration` is the touch timeout, which sets when each phase starts.
    public static func rippleProgress(elapsed: TimeInterval, touchDuration: TimeInterval = TouchTiming.cardTimeout, duration: TimeInterval = 1.2) -> Double? {
        guard elapsed >= 0 else { return nil }
        let phase = EscalationPhase.at(elapsed: elapsed, duration: touchDuration)
        let sincePhase = elapsed - phase.startsAt(duration: touchDuration)
        let t = sincePhase.truncatingRemainder(dividingBy: phase.rippleInterval) / duration
        return t < 1 ? t : nil
    }
}
