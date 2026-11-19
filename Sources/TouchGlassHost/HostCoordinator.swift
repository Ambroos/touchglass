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
    /// Drop an operation whose touch wait passed its deadline without an `op_end`.
    case touchExpired(operation: String, deadline: Date)
    /// Exit if the host is still idle; see `HostOutput.exit`.
    case retire
}

/// One card operation. A proxy connection runs its operations one after another under the same ID, so the
/// coordinator numbers them, and a label that arrives after its operation ended can't land on the next one.
public struct OperationRef: Sendable, Equatable {
    /// The proxy connection ID.
    public var conn: String
    /// The coordinator's number for the operation, unique for the host's lifetime.
    public var number: Int

    public init(conn: String, number: Int) {
        self.conn = conn
        self.number = number
    }
}

/// What a client label is for.
public enum ClientSubject: Sendable, Equatable {
    /// A card operation.
    case operation(OperationRef)
    /// A pinentry request, and the card operation it unlocks if the coordinator knows it.
    case request(id: String, operation: OperationRef?)
}

/// What the coordinator wants done.
public enum HostOutput: Sendable, Equatable {
    case panel(PanelEvent)
    case shakeField
    case reply(ConnectionID, IPCMessage)
    case schedule(after: TimeInterval, HostTimer)
    /// Find out what asked for an operation or request, off the main thread, and report it with
    /// `clientResolved(_:label:)`. The panel never waits for it.
    case resolveClient(ClientSubject, ClientQuery)
    /// Stop listening and exit the process. A helper of a later release connected, so this host runs code
    /// that `brew upgrade` replaced; the next helper that needs the host starts the installed version.
    case exit
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
    /// How long after a touch deadline the coordinator waits for the card's own timeout reply before it
    /// drops the operation.
    public static let touchExpiryGrace: TimeInterval = 2
    /// How long a retiring host stays idle before it exits, by default: longer than a result state shows,
    /// so the panel finishes what it shows, and a pinentry that connects meanwhile keeps the host.
    public static let defaultRetireAfterIdle: TimeInterval = 6

    struct CardOperation: Sendable, Equatable {
        /// See `OperationRef.number`.
        var number = 0
        var kind: TouchGlassCore.OperationKind
        var serial: String
        var pinNeeded = false
        var touchDeadline: Date?
        /// The countdown length for this operation, in seconds: the `touch-timeout` setting, or else the card's.
        var touchTimeout: TimeInterval?
        /// The card's touch timeout as the proxy reports it, in seconds.
        var cardTimeout: TimeInterval?
        /// The host connection of the proxy that reports this operation. Its operations end when it closes.
        var reporter: ConnectionID?
        /// What asked for the operation.
        var client: String?
        /// `client` came from the pinentry's owner PID, which beats a guess among the agent's clients.
        var clientIsExact = false
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
    /// The state last sent to the panel, so a late client label can update it in place.
    private(set) var panelState: PanelState?
    /// The number of operations started, for `OperationRef.number`.
    private(set) var operationCount = 0

    /// Overrides the touch timeout that the proxy reports, in seconds.
    public var touchTimeout: TimeInterval?
    /// The release this host runs, `BuildInfo.version` read at startup. Nil never retires.
    public let version: String?
    /// Connections from pinentries that are still open. A pinentry can send a request at any moment, so
    /// the host never exits while one is connected.
    private(set) var pinentryConnections: Set<ConnectionID> = []
    /// A helper of a later release said hello: exit when idle.
    public private(set) var retiring = false
    private var retireScheduled = false
    /// See `defaultRetireAfterIdle`.
    public var retireAfterIdle = Self.defaultRetireAfterIdle

    public init(touchTimeout: TimeInterval? = nil, version: String? = nil) {
        self.touchTimeout = touchTimeout
        self.version = version
    }

    // MARK: Messages

    public mutating func handle(_ message: IPCMessage, from connection: ConnectionID, now: Date) -> [HostOutput] {
        tracking(handleMessage(message, from: connection, now: now))
    }

    private mutating func handleMessage(_ message: IPCMessage, from connection: ConnectionID, now: Date) -> [HostOutput] {
        switch message {
        case .opStart(let start):
            let number = nextOperationNumber()
            operations[start.conn] = CardOperation(number: number, kind: Self.kind(start.op), serial: Self.displaySerial(start.serial), reporter: connection)
            operationOrder.removeAll { $0 == start.conn }
            operationOrder.append(start.conn)
            // PKAUTH comes from an ssh client on the agent's ssh socket; signatures and decryptions come
            // from gpg and the like on its other sockets.
            let ref = OperationRef(conn: start.conn, number: number)
            return [.resolveClient(.operation(ref), .agentClient(ssh: start.op == .auth, agent: start.agentPid))]
        case .pinNeeded(let ref):
            // The touch wait, if any, was a false start: the card asks for the PIN first.
            operations[ref.conn]?.pinNeeded = true
            operations[ref.conn]?.reporter = connection
            operations[ref.conn]?.touchDeadline = nil
            queuedTouch.removeAll { $0 == ref.conn }
            return []
        case .pinSent:
            return []
        case .touchWait(let wait):
            return touchWait(wait, from: connection, now: now)
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
        case .hello(let hello):
            if hello.role == .pinentry { pinentryConnections.insert(connection) }
            if let version, let build = hello.build, BuildInfo.isNewer(build, than: version) { retiring = true }
            return []
        case .ping, .pong, .pin, .confirmed, .notConfirmed, .cancelled, .fallback, .unknown:
            return []
        }
    }

    /// A connection closed. Operations its proxy reported end silently: a proxy that stops sends no
    /// `op_end`. Prompts it owned that the user has not answered are withdrawn.
    public mutating func connectionClosed(_ connection: ConnectionID) -> [HostOutput] {
        tracking(closeConnection(connection))
    }

    private mutating func closeConnection(_ connection: ConnectionID) -> [HostOutput] {
        pinentryConnections.remove(connection)
        var outputs: [HostOutput] = []
        for conn in operationOrder where operations[conn]?.reporter == connection {
            outputs += operationEnded(OpEnd(conn: conn, result: .cancelled))
        }
        if let shown, let id = Self.requestID(of: shown), Self.connection(of: shown) == connection {
            outputs += requestEnded(id)
        }
        return Self.mergingRearms(outputs)
    }

    // MARK: User actions

    public mutating func handle(_ action: UserAction) -> [HostOutput] {
        tracking(handleAction(action))
    }

    private mutating func handleAction(_ action: UserAction) -> [HostOutput] {
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
            return [.reply(connection, .cancelled(RequestRef(id: id))), .panel(.dismiss)] + rearmIfQueued()
        case .confirm:
            switch shown {
            case .confirm(let id, let connection), .message(let id, let connection):
                shown = nil
                return [.reply(connection, .confirmed(RequestRef(id: id))), .panel(.dismiss)] + rearmIfQueued()
            default:
                return []
            }
        case .hide:
            return [.panel(.userHid)]
        case .dismiss:
            guard case .result = shown else { return [] }
            shown = nil
            return rearmIfQueued()
        }
    }

    // MARK: Timers

    public mutating func fire(_ timer: HostTimer, now: Date) -> [HostOutput] {
        tracking(fireTimer(timer, now: now))
    }

    private mutating func fireTimer(_ timer: HostTimer, now: Date) -> [HostOutput] {
        switch timer {
        case .rearm:
            guard shown == nil || shown == .result else { return [] }
            while let next = queuedTouch.first {
                queuedTouch.removeFirst()
                guard var operation = operations[next] else { continue }
                // The queued command reaches the card only now, so its touch window starts now.
                let timeout = operation.touchTimeout ?? touchTimeout ?? TouchTiming.cardTimeout
                let deadline = now.addingTimeInterval(timeout - TouchTiming.detectionThreshold)
                operation.touchDeadline = deadline
                operations[next] = operation
                return showTouch(next, operation: operation, deadline: deadline, now: now)
            }
            return []
        case .verifyWatchdog(let requestID):
            guard case .cardPIN(requestID, _, _, _, true) = shown else { return [] }
            shown = nil
            return [.panel(.dismiss)] + rearmIfQueued()
        case .touchExpired(let conn, let deadline):
            guard let operation = operations[conn], operation.touchDeadline == deadline else { return [] }
            return operationEnded(OpEnd(conn: conn, result: .cancelled))
        case .retire:
            retireScheduled = false
            return isIdle ? [.exit] : []
        }
    }

    /// Nothing that the user sees or a helper waits for: no card operation, no pinentry connection, and at
    /// most a result state on the panel.
    var isIdle: Bool {
        operations.isEmpty && queuedTouch.isEmpty && pinentryConnections.isEmpty && (shown == nil || shown == .result)
    }

    // MARK: Client labels

    /// A client lookup finished. Stores the label with its operation and updates the panel if it shows
    /// that operation or request. A `nil` label changes nothing.
    public mutating func clientResolved(_ subject: ClientSubject, label: String?) -> [HostOutput] {
        guard let label, !label.isEmpty else { return [] }
        let operationID: String?
        let requestID: String?
        switch subject {
        case .operation(let ref):
            // A label from the owner PID is exact; a guess that arrives later must not replace it.
            guard var operation = operations[ref.conn], operation.number == ref.number, !operation.clientIsExact else { return [] }
            operation.client = label
            operations[ref.conn] = operation
            operationID = ref.conn
            requestID = nil
        case .request(let id, let ref):
            if let ref, var operation = operations[ref.conn], operation.number == ref.number {
                operation.client = label
                operation.clientIsExact = true
                operations[ref.conn] = operation
                operationID = ref.conn
            } else {
                operationID = nil
            }
            requestID = id
        }
        return tracking(refreshClient(label, operation: operationID, request: requestID))
    }

    private mutating func refreshClient(_ label: String, operation operationID: String?, request requestID: String?) -> [HostOutput] {
        switch shown {
        case .touch(let conn) where conn == operationID:
            guard case .touchWait(var wait) = panelState, wait.client != label else { return [] }
            wait.client = label
            return [.panel(.show(.touchWait(wait)))]
        case .cardPIN(let id, let connection, let conn, var request, let submitted):
            guard id == requestID || (conn != nil && conn == operationID), request.client != label else { return [] }
            request.client = label
            shown = .cardPIN(requestID: id, connection: connection, operation: conn, request: request, submitted: submitted)
            return [.panel(.show(submitted ? .verifying(request) : .pinEntry(request)))]
        case .passphrase(let id, let connection, var request, let submitted) where id == requestID:
            guard request.client != label else { return [] }
            request.client = label
            shown = .passphrase(requestID: id, connection: connection, request: request, submitted: submitted)
            return submitted ? [] : [.panel(.show(.passphrase(request)))]
        default:
            return []
        }
    }

    /// Records the last panel state in `outputs`, for `refreshClient`.
    private mutating func tracking(_ outputs: [HostOutput]) -> [HostOutput] {
        for output in outputs {
            switch output {
            case .panel(.show(let state)): panelState = state
            case .panel(.dismiss): panelState = nil
            default: break
            }
        }
        if retiring, isIdle, !retireScheduled, !outputs.contains(.exit) {
            retireScheduled = true
            return outputs + [.schedule(after: retireAfterIdle, .retire)]
        }
        return outputs
    }

    // MARK: Card events

    private mutating func touchWait(_ wait: TouchGlassIPC.TouchWait, from connection: ConnectionID, now: Date) -> [HostOutput] {
        var operation = operations[wait.conn] ?? CardOperation(number: nextOperationNumber(), kind: .unknown, serial: "")
        operation.reporter = connection
        if operations[wait.conn] == nil {
            operationOrder.append(wait.conn)
        }
        let start = wait.at.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(-TouchTiming.detectionThreshold)
        let cardTimeout = Double(wait.timeoutMs) / 1000
        let timeout = touchTimeout ?? cardTimeout
        let deadline = start.addingTimeInterval(timeout)
        operation.touchDeadline = deadline
        operation.touchTimeout = timeout
        operation.cardTimeout = cardTimeout
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
        let wait = TouchGlassCore.TouchWait(
            operation: operation.kind,
            cardSerial: operation.serial,
            deadline: deadline,
            shownAt: now,
            duration: operation.touchTimeout ?? touchTimeout ?? TouchTiming.cardTimeout,
            client: operation.client
        )
        // A touch-timeout shorter than the card's ends the countdown while the card still waits: keep the
        // panel until the card's own timeout has passed too.
        let cardWaitsLonger = max(0, (operation.cardTimeout ?? 0) - (operation.touchTimeout ?? 0))
        let expiry = max(0, deadline.timeIntervalSince(now)) + cardWaitsLonger + Self.touchExpiryGrace
        return [.panel(.show(.touchWait(wait))), .schedule(after: expiry, .touchExpired(operation: conn, deadline: deadline))]
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
        guard isShown else {
            // A touch wait that never showed, such as one queued behind a prompt, can't leave the panel stuck.
            return shown == nil || shown == .result ? rearmIfQueued() : []
        }

        let kind = operation?.kind ?? .unknown
        var outputs: [HostOutput]
        let succeeded: Bool
        switch Self.outcome(end, touchTimeout: operation?.touchTimeout ?? touchTimeout ?? TouchTiming.cardTimeout) {
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

    static func outcome(_ end: OpEnd, touchTimeout: TimeInterval = TouchTiming.cardTimeout) -> Outcome {
        let timedOut = Failure.touchTimeout(seconds: Int(touchTimeout.rounded()))
        switch end.result {
        case .ok: return .success
        case .badPin: return .failure(.wrongPIN)
        case .timeout: return .failure(timedOut)
        case .cancelled: return .silent
        case .error:
            switch end.code.map({ $0 & 0xFFFF }) {
            case ErrorCode.timeout: return .failure(timedOut)
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

        // A retry of the passphrase that is showing: same prompt, with the agent's error. Only the pinentry
        // that owns the prompt may retry it; another connection must not receive the typed secret.
        if case .passphrase(_, let shownConnection, let previous, _) = shown, shownConnection == connection {
            let next = PassphraseRequest(description: request.desc ?? "", error: request.error, client: previous.client, promptID: previous.promptID)
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
        // The agent names its client in the owner option: an exact answer, where the proxy's operation
        // only allows a guess among the agent's clients.
        let operationRef = operationID.flatMap { conn in operations[conn].map { OperationRef(conn: conn, number: $0.number) } }
        let resolve: [HostOutput] = ClientQuery.ownerPID(request.owner).map {
            [.resolveClient(.request(id: request.id, operation: operationRef), .owner($0))]
        } ?? []

        guard isCard else {
            let passphrase = PassphraseRequest(description: request.desc ?? "", error: request.error, promptID: request.id)
            shown = .passphrase(requestID: request.id, connection: connection, request: passphrase, submitted: false)
            return [.panel(.show(.passphrase(passphrase)))] + resolve
        }

        let operation = operationID.flatMap { operations[$0] }
        let serial = Self.displaySerial(request.fields?.number).nonEmpty ?? operation?.serial ?? ""
        let pin = PinRequest(
            operation: operation?.kind ?? .unknown,
            pin: text.localizedCaseInsensitiveContains("admin") ? .admin : .user,
            cardSerial: serial,
            attemptsLeft: Self.attemptsLeft(in: request.desc),
            client: operation?.client,
            promptID: request.id
        )
        shown = .cardPIN(requestID: request.id, connection: connection, operation: operationID, request: pin, submitted: false)
        return [.panel(.show(.pinEntry(pin)))] + resolve
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
        return [.panel(.dismiss)] + rearmIfQueued()
    }

    /// Schedules the next queued touch wait once nothing holds the panel. Every path that clears `shown`
    /// calls this, so a touch wait queued behind a prompt shows however the prompt ends.
    private func rearmIfQueued() -> [HostOutput] {
        guard !queuedTouch.isEmpty, shown == nil || shown == .result else { return [] }
        return [.schedule(after: Self.rearmAfterSuccess, .rearm)]
    }

    /// Keeps the first `.rearm` and drops the rest, for a step that ends several operations at once.
    static func mergingRearms(_ outputs: [HostOutput]) -> [HostOutput] {
        var seen = false
        return outputs.filter {
            guard case .schedule(_, .rearm) = $0 else { return true }
            defer { seen = true }
            return !seen
        }
    }

    // MARK: Helpers

    private mutating func nextOperationNumber() -> Int {
        operationCount += 1
        return operationCount
    }

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
