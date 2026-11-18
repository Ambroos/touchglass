import Foundation
import TouchGlassCore
import TouchGlassIPC

/// Identifies one accepted connection to the host socket.
public typealias ConnectionID = Int

/// A user action on the panel, as the coordinator sees it.
public enum UserAction: Sendable {
    /// The secure field was submitted. The string is the secret; never log or print it.
    case submit(String)
    case cancel
    case confirm
    case hide
    /// A click on an error state.
    case dismiss
}

/// A delayed step the coordinator asks for.
public enum HostTimer: Sendable, Equatable {
    /// Show the next queued touch wait.
    case rearm
    /// Give up on a submitted PIN whose card operation never reported back.
    case verifyWatchdog(requestID: String)
}

/// What the coordinator wants done.
public enum HostOutput: Sendable, Equatable {
    case panel(PanelEvent)
    case shakeField
    case reply(ConnectionID, IPCMessage)
    case schedule(after: TimeInterval, HostTimer)
}

/// Merges the proxy's card events and the pinentry's prompts into one panel.
///
/// Pure: it has no clock, threads or UI. `HostSession` feeds it messages, user actions and timers,
/// and performs its outputs.
public struct HostCoordinator: Sendable {
    /// How long a submitted card PIN may stay in the verifying state without a card event.
    public static let verifyTimeout: TimeInterval = 30
    /// Delay before showing a queued touch wait after the previous operation ended.
    public static let rearmAfterSuccess: TimeInterval = 0.5
    public static let rearmAfterFailure: TimeInterval = 1.5

    struct CardOperation: Sendable, Equatable {
        var kind: TouchGlassCore.OperationKind
        var serial: String
        var pinNeeded = false
        var touchDeadline: Date?
    }

    enum Shown: Sendable, Equatable {
        /// A card PIN prompt. `submitted` turns it into the verifying state.
        case cardPIN(requestID: String, connection: ConnectionID, operation: String?, request: PinRequest, submitted: Bool)
        case passphrase(requestID: String, connection: ConnectionID, request: PassphraseRequest, submitted: Bool)
        case confirm(requestID: String, connection: ConnectionID)
        case message(requestID: String, connection: ConnectionID)
        case touch(operation: String)
        /// A success or error state for a finished operation.
        case result
    }

    private(set) var operations: [String: CardOperation] = [:]
    /// Operation connection IDs in start order.
    private(set) var operationOrder: [String] = []
    /// Operations that reached touch wait while another one's panel was showing.
    private(set) var queuedTouch: [String] = []
    private(set) var shown: Shown?

    public init() {}

    // MARK: Messages

    public mutating func handle(_ message: IPCMessage, from connection: ConnectionID, now: Date) -> [HostOutput] {
        switch message {
        case .opStart(let start):
            operations[start.conn] = CardOperation(kind: Self.kind(start.op), serial: Self.displaySerial(start.serial))
            operationOrder.removeAll { $0 == start.conn }
            operationOrder.append(start.conn)
            return []
        case .pinNeeded(let ref):
            // The touch wait, if any, was a false start: the card asks for the PIN first.
            operations[ref.conn]?.pinNeeded = true
            operations[ref.conn]?.touchDeadline = nil
            queuedTouch.removeAll { $0 == ref.conn }
            return []
        case .pinSent:
            return []
        case .touchWait(let wait):
            return touchWait(wait, now: now)
        case .opEnd(let end):
            return operationEnded(end)
        case .getPin(let request):
            return getPin(request, from: connection)
        case .confirm(let request):
            return confirm(request, from: connection)
        case .message(let request):
            return showMessage(request, from: connection)
        case .dismiss(let ref):
            return requestEnded(ref.id)
        case .hello, .ping, .pong, .pin, .confirmed, .notConfirmed, .cancelled, .fallback, .unknown:
            return []
        }
    }

    /// A connection closed. Prompts it owned that the user has not answered are withdrawn.
    public mutating func connectionClosed(_ connection: ConnectionID) -> [HostOutput] {
        guard let shown, let id = Self.requestID(of: shown), Self.connection(of: shown) == connection else { return [] }
        return requestEnded(id)
    }

    // MARK: User actions

    public mutating func handle(_ action: UserAction) -> [HostOutput] {
        switch action {
        case .submit(let secret):
            switch shown {
            case .cardPIN(let id, let connection, let operation, let request, false):
                shown = .cardPIN(requestID: id, connection: connection, operation: operation, request: request, submitted: true)
                return [
                    .reply(connection, .pin(PinReply(id: id, secret: Data(secret.utf8)))),
                    .panel(.show(.verifying(request))),
                    .schedule(after: Self.verifyTimeout, .verifyWatchdog(requestID: id)),
                ]
            case .passphrase(let id, let connection, let request, false):
                shown = .passphrase(requestID: id, connection: connection, request: request, submitted: true)
                return [.reply(connection, .pin(PinReply(id: id, secret: Data(secret.utf8))))]
            default:
                return []
            }
        case .cancel:
            guard let current = shown, let id = Self.requestID(of: current), let connection = Self.connection(of: current), !Self.isSubmitted(current) else {
                return []
            }
            shown = nil
            return [.reply(connection, .cancelled(RequestRef(id: id))), .panel(.dismiss)]
        case .confirm:
            switch shown {
            case .confirm(let id, let connection), .message(let id, let connection):
                shown = nil
                return [.reply(connection, .confirmed(RequestRef(id: id))), .panel(.dismiss)]
            default:
                return []
            }
        case .hide:
            return [.panel(.userHid)]
        case .dismiss:
            if case .result = shown { shown = nil }
            return []
        }
    }

    // MARK: Timers

    public mutating func fire(_ timer: HostTimer, now: Date) -> [HostOutput] {
        switch timer {
        case .rearm:
            guard shown == nil || shown == .result else { return [] }
            while let next = queuedTouch.first {
                queuedTouch.removeFirst()
                guard var operation = operations[next] else { continue }
                // The queued command reaches the card only now, so its touch window starts now.
                let deadline = now.addingTimeInterval(TouchTiming.cardTimeout - TouchTiming.detectionThreshold)
                operation.touchDeadline = deadline
                operations[next] = operation
                return showTouch(next, operation: operation, deadline: deadline, now: now)
            }
            return []
        case .verifyWatchdog(let requestID):
            guard case .cardPIN(requestID, _, _, _, true) = shown else { return [] }
            shown = nil
            return [.panel(.dismiss)]
        }
    }

    // MARK: Card events

    private mutating func touchWait(_ wait: TouchGlassIPC.TouchWait, now: Date) -> [HostOutput] {
        var operation = operations[wait.conn] ?? CardOperation(kind: .unknown, serial: "")
        if operations[wait.conn] == nil {
            operationOrder.append(wait.conn)
        }
        let start = wait.at.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(-TouchTiming.detectionThreshold)
        let deadline = start.addingTimeInterval(Double(wait.timeoutMs) / 1000)
        operation.touchDeadline = deadline
        operation.pinNeeded = false
        operations[wait.conn] = operation

        switch shown {
        case .touch(let other) where other != wait.conn && operations[other] != nil:
            // Card operations serialise on the card: keep one panel and re-arm it later.
            if !queuedTouch.contains(wait.conn) { queuedTouch.append(wait.conn) }
            return []
        case .cardPIN(_, _, _, _, false), .passphrase(_, _, _, false), .confirm, .message:
            // A prompt is waiting for the user; show this touch after it.
            if !queuedTouch.contains(wait.conn) { queuedTouch.append(wait.conn) }
            return []
        default:
            return showTouch(wait.conn, operation: operation, deadline: deadline, now: now)
        }
    }

    private mutating func showTouch(_ conn: String, operation: CardOperation, deadline: Date, now: Date) -> [HostOutput] {
        shown = .touch(operation: conn)
        let wait = TouchGlassCore.TouchWait(operation: operation.kind, cardSerial: operation.serial, deadline: deadline, shownAt: now)
        return [.panel(.show(.touchWait(wait)))]
    }

    private mutating func operationEnded(_ end: OpEnd) -> [HostOutput] {
        let operation = operations.removeValue(forKey: end.conn)
        operationOrder.removeAll { $0 == end.conn }
        queuedTouch.removeAll { $0 == end.conn }

        let isShown: Bool
        switch shown {
        case .touch(let conn): isShown = conn == end.conn
        case .cardPIN(_, _, let conn?, _, true): isShown = conn == end.conn
        default: isShown = false
        }
        guard isShown else { return [] }

        let kind = operation?.kind ?? .unknown
        var outputs: [HostOutput]
        let succeeded: Bool
        switch Self.outcome(end) {
        case .success:
            shown = .result
            outputs = [.panel(.show(.success(kind)))]
            succeeded = true
        case .failure(let failure):
            shown = .result
            outputs = [.panel(.show(.failure(failure)))]
            succeeded = false
        case .silent:
            shown = nil
            outputs = [.panel(.dismiss)]
            succeeded = false
        }
        if !queuedTouch.isEmpty {
            outputs.append(.schedule(after: succeeded ? Self.rearmAfterSuccess : Self.rearmAfterFailure, .rearm))
        }
        return outputs
    }

    enum Outcome: Equatable {
        case success
        case failure(Failure)
        /// Close without an error state: the user or the agent cancelled.
        case silent
    }

    /// gpg-error codes, without the source bits.
    enum ErrorCode {
        static let timeout = 62
        static let badPIN = 87
        static let canceled = 99
        static let cardRemoved = 110
        static let cardNotPresent = 112
        static let pinBlocked = 130
    }

    static func outcome(_ end: OpEnd) -> Outcome {
        switch end.result {
        case .ok: return .success
        case .badPin: return .failure(.wrongPIN)
        case .timeout: return .failure(.touchTimeout)
        case .cancelled: return .silent
        case .error:
            switch end.code.map({ $0 & 0xFFFF }) {
            case ErrorCode.timeout: return .failure(.touchTimeout)
            case ErrorCode.badPIN: return .failure(.wrongPIN)
            case ErrorCode.canceled: return .silent
            case ErrorCode.cardRemoved, ErrorCode.cardNotPresent: return .failure(.cardRemoved)
            case ErrorCode.pinBlocked: return .failure(.pinBlocked)
            case let code?: return .failure(.other("The card reported error \(code)."))
            case nil: return .failure(.other("The card operation stopped."))
            }
        }
    }

    // MARK: Pinentry requests

    /// A prompt that holds the keyboard and has not been answered.
    private var isAwaitingUser: Bool {
        switch shown {
        case .cardPIN(_, _, _, _, false), .passphrase(_, _, _, false), .confirm, .message: true
        default: false
        }
    }

    private mutating func getPin(_ request: GetPin, from connection: ConnectionID) -> [HostOutput] {
        let text = [request.title, request.desc, request.prompt].compactMap { $0 }.joined(separator: "\n")

        // A retry of the passphrase that is showing: same prompt, with the agent's error.
        if case .passphrase(_, let shownConnection, _, _) = shown, shownConnection == connection || request.error != nil {
            let next = PassphraseRequest(description: request.desc ?? "", error: request.error)
            shown = .passphrase(requestID: request.id, connection: connection, request: next, submitted: false)
            return [.panel(.show(.passphrase(next))), .shakeField]
        }
        if isAwaitingUser {
            return [.reply(connection, .fallback(RequestRef(id: request.id)))]
        }
        // Reset codes and PUKs are rare and need different copy: hand them to pinentry-mac.
        if text.localizedCaseInsensitiveContains("reset code") || text.localizedCaseInsensitiveContains("PUK") {
            return [.reply(connection, .fallback(RequestRef(id: request.id)))]
        }

        let operationID = operationOrder.last { operations[$0]?.pinNeeded == true }
            ?? (request.fields != nil ? operationOrder.last : nil)
        let isCard = operationID != nil || request.fields != nil

        guard isCard else {
            let passphrase = PassphraseRequest(description: request.desc ?? "", error: request.error)
            shown = .passphrase(requestID: request.id, connection: connection, request: passphrase, submitted: false)
            return [.panel(.show(.passphrase(passphrase)))]
        }

        let operation = operationID.flatMap { operations[$0] }
        let serial = Self.displaySerial(request.fields?.number).nonEmpty ?? operation?.serial ?? ""
        let pin = PinRequest(
            operation: operation?.kind ?? .unknown,
            pin: text.localizedCaseInsensitiveContains("admin") ? .admin : .user,
            cardSerial: serial,
            attemptsLeft: Self.attemptsLeft(in: request.desc)
        )
        shown = .cardPIN(requestID: request.id, connection: connection, operation: operationID, request: pin, submitted: false)
        return [.panel(.show(.pinEntry(pin)))]
    }

    private mutating func confirm(_ request: Confirm, from connection: ConnectionID) -> [HostOutput] {
        // Three-button confirms have no layout in the panel.
        if isAwaitingUser || request.notok != nil {
            return [.reply(connection, .fallback(RequestRef(id: request.id)))]
        }
        let (title, detail) = Self.split(request.title, request.desc)
        if request.oneButton {
            shown = .message(requestID: request.id, connection: connection)
            return [.panel(.show(.message(TouchGlassCore.MessageRequest(title: title, detail: detail, okLabel: Self.label(request.ok, default: "OK")))))]
        }
        let purpose: ConfirmRequest.Purpose = (request.desc ?? "").localizedCaseInsensitiveContains("insert") ? .insertCard : .generic
        shown = .confirm(requestID: request.id, connection: connection)
        let state = ConfirmRequest(
            purpose: purpose,
            title: purpose == .insertCard ? "Insert your YubiKey" : title,
            detail: purpose == .insertCard ? (request.desc ?? detail) : detail,
            okLabel: Self.label(request.ok, default: "OK"),
            cancelLabel: Self.label(request.cancel, default: "Cancel")
        )
        return [.panel(.show(.confirm(state)))]
    }

    private mutating func showMessage(_ request: TouchGlassIPC.MessageRequest, from connection: ConnectionID) -> [HostOutput] {
        if isAwaitingUser {
            return [.reply(connection, .fallback(RequestRef(id: request.id)))]
        }
        let (title, detail) = Self.split(request.title, request.desc)
        shown = .message(requestID: request.id, connection: connection)
        return [.panel(.show(.message(TouchGlassCore.MessageRequest(title: title, detail: detail, okLabel: Self.label(request.ok, default: "OK")))))]
    }

    /// The pinentry withdrew a request, or its connection closed.
    private mutating func requestEnded(_ id: String) -> [HostOutput] {
        guard let current = shown, Self.requestID(of: current) == id else { return [] }
        // A submitted card PIN tied to an operation stays as "verifying" until the card answers.
        if case .cardPIN(_, _, let operation?, _, true) = current, operations[operation] != nil {
            return []
        }
        shown = nil
        return [.panel(.dismiss)]
    }

    // MARK: Helpers

    static func kind(_ kind: TouchGlassIPC.OperationKind) -> TouchGlassCore.OperationKind {
        switch kind {
        case .sign: .sign
        case .auth: .sshLogin
        case .decrypt: .decrypt
        }
    }

    /// A card serial as printed on a YubiKey: the agent's spaced form ("12 345 678") without
    /// spaces. A full OpenPGP application ID yields its 8-digit serial number field.
    static func displaySerial(_ raw: String?) -> String {
        guard let raw else { return "" }
        let compact = raw.filter { !$0.isWhitespace }
        if compact.count == 32, compact.hasPrefix("D276000124") {
            // Application ID: RID, application, version, manufacturer (4 hex), serial (8 hex), RFU.
            let start = compact.index(compact.startIndex, offsetBy: 20)
            let end = compact.index(start, offsetBy: 8)
            let hex = String(compact[start..<end])
            return hex.allSatisfy(\.isNumber) ? String(hex.drop { $0 == "0" }) : hex
        }
        return compact
    }

    /// The remaining attempts, when the agent's description names them. Localized text, so this
    /// looks for the number after a word that contains "attempt" and gives up otherwise.
    static func attemptsLeft(in description: String?) -> Int? {
        guard let description, let range = description.range(of: "attempt", options: .caseInsensitive) else { return nil }
        let after = description[range.upperBound...].drop { !$0.isNumber }
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }

    /// The first line becomes the title, the rest the detail. An explicit title wins.
    static func split(_ title: String?, _ description: String?) -> (String, String) {
        let text = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return (title, text) }
        guard let newline = text.firstIndex(of: "\n") else { return (text, "") }
        return (String(text[..<newline]), String(text[newline...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes accelerator underscores from an agent button label.
    static func label(_ raw: String?, default fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        return raw.replacingOccurrences(of: "_", with: "")
    }

    static func requestID(of shown: Shown) -> String? {
        switch shown {
        case .cardPIN(let id, _, _, _, _), .passphrase(let id, _, _, _), .confirm(let id, _), .message(let id, _): id
        case .touch, .result: nil
        }
    }

    static func connection(of shown: Shown) -> ConnectionID? {
        switch shown {
        case .cardPIN(_, let c, _, _, _), .passphrase(_, let c, _, _), .confirm(_, let c), .message(_, let c): c
        case .touch, .result: nil
        }
    }

    static func isSubmitted(_ shown: Shown) -> Bool {
        switch shown {
        case .cardPIN(_, _, _, _, let submitted), .passphrase(_, _, _, let submitted): submitted
        default: false
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
