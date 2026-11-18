import Foundation

/// A colour role. The panel maps these to system semantic colours.
public enum ColorRole: Sendable, Equatable {
    case primary
    case accent
    case success
    case failure
    case warning
    /// The symbol's own multicolour rendering.
    case multicolor
}

public struct Glyph: Sendable, Equatable {
    public var symbol: String
    public var fallback: String?
    public var color: ColorRole
    public var pointSize: Double

    public init(_ symbol: String, fallback: String? = nil, color: ColorRole = .accent, pointSize: Double = 40) {
        self.symbol = symbol
        self.fallback = fallback
        self.color = color
        self.pointSize = pointSize
    }
}

/// What the stage region shows.
public enum Stage: Sendable, Equatable {
    case glyph(Glyph)
    /// The countdown ring. `nil` while waiting; the operation once it succeeded.
    case ring(TouchWait?, completed: Bool)
}

public enum Controls: Sendable, Equatable {
    case none
    /// `prompt` is the request's `promptID`: the field starts empty when it changes.
    case secureField(placeholder: String, minimumLength: Int, cancel: String, submit: String, busy: Bool, prompt: String?)
    case countdown(TouchWait)
    /// Keeps the countdown slot's height in the success state, so the ring does not move.
    case countdownPlaceholder
    case confirm(cancel: String, ok: String)
    case acknowledge(ok: String)
}

/// The text and controls for one panel state. Pure: no clock, no UI types.
public struct PanelPresentation: Sendable, Equatable {
    public var stage: Stage
    public var title: String
    public var detail: String?
    public var detailIsError: Bool
    public var detailLineLimit: Int
    /// What asked for the operation, on its own line under the detail. Not part of the announcement:
    /// it often arrives a moment later, and announcing the state again for it would repeat the title.
    public var clientLine: String? = nil
    /// The state keeps a line for `clientLine` even while it is empty, so a label that arrives late
    /// does not move the rest of the panel.
    public var reservesClientLine = false
    public var attemptsLine: String?
    public var controls: Controls
    /// Identifies which states share a layout, so that changes inside a group do not crossfade.
    public var layoutGroup: String

    public var announcement: String {
        [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

public enum Copy {
    public static func operationGlyph(_ kind: OperationKind) -> Glyph {
        switch kind {
        case .sign: Glyph("signature", fallback: "pencil.and.scribble")
        case .sshLogin: Glyph("terminal.fill", fallback: "key.horizontal.fill")
        case .decrypt: Glyph("lock.open.fill", fallback: "lock.fill")
        case .unknown: Glyph("key.horizontal.fill", fallback: "key.fill")
        }
    }

    public static func pinTitle(_ request: PinRequest) -> String {
        if request.pin == .admin { return "Enter Admin PIN" }
        switch request.operation {
        case .sign: return "Enter PIN to sign"
        case .sshLogin: return "Enter PIN for SSH login"
        case .decrypt: return "Enter PIN to decrypt"
        case .unknown: return "Enter PIN"
        }
    }

    public static func attemptsLine(_ attempts: Int?) -> String? {
        guard let attempts, attempts < 3 else { return nil }
        if attempts <= 1 { return "1 attempt left. A wrong PIN blocks the card." }
        return "\(attempts) attempts left"
    }

    /// "YubiKey 12345678", or "YubiKey" when the serial is unknown.
    public static func card(_ serial: String) -> String {
        serial.isEmpty ? "YubiKey" : "YubiKey \(serial)"
    }

    public static func touchDetail(_ wait: TouchWait) -> String {
        let card = wait.cardSerial.isEmpty ? "your YubiKey" : "YubiKey \(wait.cardSerial)"
        switch wait.operation {
        case .sign: return "Signing with \(card)"
        case .sshLogin: return "SSH login with \(card)"
        case .decrypt: return "Decrypting with \(card)"
        case .unknown: return "Using \(card)"
        }
    }

    public static func successTitle(_ kind: OperationKind) -> String {
        switch kind {
        case .sign: "Signed"
        case .sshLogin: "Logged in"
        case .decrypt: "Decrypted"
        case .unknown: "Done"
        }
    }

    /// "12 seconds left", "1 second left". Rounds up so the line reaches 0 when the ring empties.
    public static func countdown(remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return seconds == 1 ? "1 second left" : "\(seconds) seconds left"
    }

    public static func timeLeftAnnouncement(remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return seconds == 1 ? "1 second left to touch your YubiKey" : "\(seconds) seconds left to touch your YubiKey"
    }
}

extension PanelPresentation {
    public init(_ state: PanelState) {
        switch state {
        case .pinEntry(let request), .verifying(let request):
            let busy: Bool
            if case .verifying = state { busy = true } else { busy = false }
            self.init(
                stage: .glyph(Copy.operationGlyph(request.operation)),
                title: Copy.pinTitle(request),
                detail: Copy.card(request.cardSerial),
                detailIsError: false,
                detailLineLimit: 2,
                clientLine: request.client,
                reservesClientLine: true,
                attemptsLine: Copy.attemptsLine(request.attemptsLeft),
                controls: .secureField(
                    placeholder: request.pin == .admin ? "Admin PIN" : "PIN",
                    minimumLength: request.minimumLength,
                    cancel: "Cancel",
                    submit: "Unlock",
                    busy: busy,
                    prompt: request.promptID
                ),
                layoutGroup: "pin"
            )
        case .passphrase(let request):
            self.init(
                stage: .glyph(Glyph("key.fill", fallback: "lock.fill")),
                title: "Enter passphrase",
                detail: request.error ?? request.description,
                detailIsError: request.error != nil,
                detailLineLimit: 2,
                clientLine: request.client,
                reservesClientLine: true,
                attemptsLine: nil,
                controls: .secureField(placeholder: "Passphrase", minimumLength: 1, cancel: "Cancel", submit: "Unlock", busy: false, prompt: request.promptID),
                layoutGroup: "pin"
            )
        case .touchWait(let wait):
            self.init(
                stage: .ring(wait, completed: false),
                title: "Touch your YubiKey",
                detail: Copy.touchDetail(wait),
                detailIsError: false,
                detailLineLimit: 2,
                clientLine: wait.client,
                reservesClientLine: true,
                attemptsLine: nil,
                controls: .countdown(wait),
                layoutGroup: "touch"
            )
        case .success(let kind):
            self.init(
                stage: .ring(nil, completed: true),
                title: Copy.successTitle(kind),
                detail: nil,
                detailIsError: false,
                detailLineLimit: 2,
                // Same reservation as the touch step, so the ring does not move.
                reservesClientLine: true,
                attemptsLine: nil,
                controls: .countdownPlaceholder,
                layoutGroup: "touch"
            )
        case .failure(let failure):
            let (glyph, title, detail) = Self.failureCopy(failure)
            self.init(
                stage: .glyph(glyph),
                title: title,
                detail: detail,
                detailIsError: false,
                detailLineLimit: 2,
                attemptsLine: nil,
                controls: .none,
                layoutGroup: "failure"
            )
        case .confirm(let request):
            let glyph = request.purpose == .insertCard
                ? Glyph("key.horizontal", fallback: "key")
                : Glyph("questionmark.circle.fill")
            self.init(
                stage: .glyph(glyph),
                title: request.title,
                detail: request.detail,
                detailIsError: false,
                detailLineLimit: 4,
                attemptsLine: nil,
                controls: .confirm(cancel: request.cancelLabel, ok: request.okLabel),
                layoutGroup: "confirm"
            )
        case .message(let request):
            self.init(
                stage: .glyph(Glyph("exclamationmark.triangle.fill", color: .multicolor)),
                title: request.title,
                detail: request.detail,
                detailIsError: false,
                detailLineLimit: 4,
                attemptsLine: nil,
                controls: .acknowledge(ok: request.okLabel),
                layoutGroup: "confirm"
            )
        }
    }

    private static func failureCopy(_ failure: Failure) -> (Glyph, String, String) {
        switch failure {
        case .touchTimeout(let seconds):
            (Glyph("clock.badge.exclamationmark", fallback: "exclamationmark.triangle.fill", color: .warning, pointSize: 44),
             "Touch timed out",
             "The YubiKey waited \(seconds) seconds. The next attempt asks for your PIN again.")
        case .wrongPIN:
            (Glyph("xmark.circle.fill", color: .failure, pointSize: 44),
             "Wrong PIN",
             "The YubiKey rejected the PIN. Run the command again.")
        case .pinBlocked:
            (Glyph("lock.slash.fill", fallback: "exclamationmark.lock.fill", color: .failure, pointSize: 44),
             "PIN blocked",
             "Unblock it with the Admin PIN in gpg --card-edit.")
        case .cardRemoved:
            (Glyph("key.horizontal", fallback: "key", color: .primary, pointSize: 44),
             "YubiKey removed",
             "The operation stopped. Run the command again.")
        case .other(let message):
            (Glyph("exclamationmark.triangle.fill", color: .multicolor, pointSize: 44),
             "Operation failed",
             message)
        }
    }
}
