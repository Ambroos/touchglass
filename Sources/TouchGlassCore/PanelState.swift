import Foundation

/// The card operation a panel is about. The host learns it from the scdaemon command
/// (`PKSIGN`, `PKAUTH`, `PKDECRYPT`); it does not know what the signature is for.
public enum OperationKind: String, Sendable, Equatable, CaseIterable {
    case sign
    case sshLogin
    case decrypt
    case unknown
}

/// Which card PIN is being asked for.
public enum PinKind: Sendable, Equatable {
    case user
    case admin

    /// scdaemon rejects shorter values without asking the card.
    public var minimumLength: Int {
        switch self {
        case .user: 6
        case .admin: 8
        }
    }
}

public struct PinRequest: Sendable, Equatable {
    public var operation: OperationKind
    public var pin: PinKind
    public var cardSerial: String
    /// Attempts left, only when the agent reports fewer than 3.
    public var attemptsLeft: Int?
    /// Overrides `pin.minimumLength`. Demo mode sets 1 so that any text continues.
    public var minimumLengthOverride: Int?

    public init(operation: OperationKind, pin: PinKind = .user, cardSerial: String, attemptsLeft: Int? = nil, minimumLengthOverride: Int? = nil) {
        self.operation = operation
        self.pin = pin
        self.cardSerial = cardSerial
        self.attemptsLeft = attemptsLeft
        self.minimumLengthOverride = minimumLengthOverride
    }

    public var minimumLength: Int { minimumLengthOverride ?? pin.minimumLength }
}

public struct PassphraseRequest: Sendable, Equatable {
    /// The agent's description, shown verbatim.
    public var description: String
    /// The agent's error text after a rejected passphrase, shown verbatim.
    public var error: String?

    public init(description: String, error: String? = nil) {
        self.description = description
        self.error = error
    }
}

public struct TouchWait: Sendable, Equatable {
    public var operation: OperationKind
    public var cardSerial: String
    /// When the card stops waiting: the time the command reached scdaemon plus `TouchTiming.cardTimeout`.
    public var deadline: Date
    /// When the panel showed the touch step. Escalation phases count from here.
    public var shownAt: Date

    public init(operation: OperationKind, cardSerial: String, deadline: Date, shownAt: Date) {
        self.operation = operation
        self.cardSerial = cardSerial
        self.deadline = deadline
        self.shownAt = shownAt
    }

    /// A touch wait whose command started `TouchTiming.detectionThreshold` before `now`.
    public static func detected(operation: OperationKind, cardSerial: String, now: Date = Date()) -> TouchWait {
        TouchWait(
            operation: operation,
            cardSerial: cardSerial,
            deadline: now.addingTimeInterval(TouchTiming.cardTimeout - TouchTiming.detectionThreshold),
            shownAt: now
        )
    }

    public func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    public func fractionRemaining(at date: Date) -> Double {
        min(1, remaining(at: date) / TouchTiming.cardTimeout)
    }
}

public enum Failure: Sendable, Equatable {
    case touchTimeout
    case wrongPIN
    case pinBlocked
    case cardRemoved
    /// Any other card error, with the text of the `ERR` line.
    case other(String)
}

public struct ConfirmRequest: Sendable, Equatable {
    public enum Purpose: Sendable, Equatable {
        case generic
        case insertCard
    }

    public var purpose: Purpose
    public var title: String
    public var detail: String
    public var okLabel: String
    public var cancelLabel: String

    public init(purpose: Purpose = .generic, title: String, detail: String, okLabel: String = "OK", cancelLabel: String = "Cancel") {
        self.purpose = purpose
        self.title = title
        self.detail = detail
        self.okLabel = okLabel
        self.cancelLabel = cancelLabel
    }
}

public struct MessageRequest: Sendable, Equatable {
    public var title: String
    public var detail: String
    public var okLabel: String

    public init(title: String, detail: String, okLabel: String = "OK") {
        self.title = title
        self.detail = detail
        self.okLabel = okLabel
    }
}

/// Everything the panel can show. One value fully describes the panel's content.
public enum PanelState: Sendable, Equatable {
    case pinEntry(PinRequest)
    case verifying(PinRequest)
    case passphrase(PassphraseRequest)
    case touchWait(TouchWait)
    case success(OperationKind)
    case failure(Failure)
    case confirm(ConfirmRequest)
    case message(MessageRequest)

    /// Whether the panel takes keyboard focus in this state.
    public var allowsKey: Bool {
        switch self {
        case .pinEntry, .verifying, .passphrase, .confirm, .message: true
        case .touchWait, .success, .failure: false
        }
    }
}
