import Foundation

// Messages exchanged over the host socket. Each message is one JSON object on one line, tagged by its "type" field. Field names are snake_case on the wire.
//
// Directions:
// - Proxy to host: opStart, pinNeeded, pinSent, touchWait, opEnd, touchPolicy. Fire-and-forget.
// - Pinentry to host: getPin, confirm, message, dismiss, ping.
// - Host to pinentry: pin, confirmed, notConfirmed, cancelled, fallback, pong.
// - Either helper sends hello first.

/// The kind of card operation, as the proxy infers it from the slot and the command.
public enum OperationKind: String, Codable, Sendable, Equatable {
    case sign
    case auth
    case decrypt
}

/// How a card operation ended.
public enum OperationResult: String, Codable, Sendable, Equatable {
    case ok
    case badPin = "bad_pin"
    case timeout
    case cancelled
    case error
}

/// Sender of a hello message.
public enum PeerRole: String, Codable, Sendable, Equatable {
    case pinentry
    case proxy
}

public struct Hello: Codable, Sendable, Equatable {
    public var role: PeerRole
    public var pid: Int32
    /// The IPC protocol version, `IPCProtocol.version`.
    public var version: String
    /// The TouchGlass release the helper belongs to, such as "0.2.0". A host that is older than one of
    /// its helpers exits when idle, so the next helper starts the installed version. Optional, so hosts
    /// and helpers of different versions understand each other.
    public var build: String?
    /// The proxy's GnuPG installation, so the host can ask gpg-agent about a card. Proxies only; optional.
    public var gnupg: GnuPGContext?

    public init(role: PeerRole, pid: Int32 = getpid(), version: String = IPCProtocol.version, build: String? = BuildInfo.version, gnupg: GnuPGContext? = nil) {
        self.role = role
        self.pid = pid
        self.version = version
        self.build = build
        self.gnupg = gnupg
    }
}

/// Where the gpg-agent that runs a proxy lives.
public struct GnuPGContext: Codable, Sendable, Equatable {
    /// The GnuPG home directory that gpg-agent passed to scdaemon with `--homedir`, or `GNUPGHOME`. Nil for
    /// the default, `~/.gnupg`.
    public var home: String?
    /// The directory that holds `gpg-connect-agent`: the `bin` directory next to the real scdaemon's
    /// `libexec`. Nil when unknown.
    public var binDir: String?

    public init(home: String? = nil, binDir: String? = nil) {
        self.home = home
        self.binDir = binDir
    }

    enum CodingKeys: String, CodingKey {
        case home
        case binDir = "bin_dir"
    }
}

// MARK: Proxy events

public struct OpStart: Codable, Sendable, Equatable {
    /// Connection ID, unique across proxy processes, such as "12345:s3".
    public var conn: String
    public var op: OperationKind
    /// OpenPGP key slot: 1 sig, 2 dec, 3 aut.
    public var slot: Int?
    public var serial: String?
    /// Unix time in seconds when the operation command reached scdaemon.
    public var at: Double?
    /// The gpg-agent that runs the proxy, which is the agent whose client asked for the operation. Optional,
    /// so hosts and proxies of different versions understand each other.
    public var agentPid: Int32?

    public init(conn: String, op: OperationKind, slot: Int? = nil, serial: String? = nil, at: Double? = nil, agentPid: Int32? = nil) {
        self.conn = conn
        self.op = op
        self.slot = slot
        self.serial = serial
        self.at = at
        self.agentPid = agentPid
    }

    enum CodingKeys: String, CodingKey {
        case conn, op, slot, serial, at
        case agentPid = "agent_pid"
    }
}

public struct ConnRef: Codable, Sendable, Equatable {
    public var conn: String

    public init(conn: String) {
        self.conn = conn
    }
}

public struct TouchWait: Codable, Sendable, Equatable {
    public var conn: String
    public var timeoutMs: Int
    /// Unix time in seconds from which the card's touch timeout runs.
    public var at: Double?
    /// scdaemon said that the card waits for the touch, with `POPUPPINPADPROMPT --ack`, instead of the
    /// proxy inferring it from silence. Optional; nil means inferred.
    public var pinpad: Bool?

    public init(conn: String, timeoutMs: Int = 15_000, at: Double? = nil, pinpad: Bool? = nil) {
        self.conn = conn
        self.timeoutMs = timeoutMs
        self.at = at
        self.pinpad = pinpad
    }

    enum CodingKeys: String, CodingKey {
        case conn
        case timeoutMs = "timeout_ms"
        case at, pinpad
    }
}

public struct OpEnd: Codable, Sendable, Equatable {
    public var conn: String
    public var result: OperationResult
    /// The raw gpg-error number from the ERR line, if any.
    public var code: Int?

    public init(conn: String, result: OperationResult, code: Int? = nil) {
        self.conn = conn
        self.result = result
        self.code = code
    }
}

/// A card reported the touch policy of one key slot: an `S UIF-<slot>` status line that passed through the
/// proxy, after an `S SERIALNO` on the same connection named the card.
public struct TouchPolicyReport: Codable, Sendable, Equatable {
    /// The card's serial number as scdaemon reports it: for an OpenPGP card, the application ID in hex.
    public var serial: String
    /// OpenPGP key slot: 1 sig, 2 dec, 3 aut.
    public var slot: Int
    /// The first byte of the UIF data object, or nil when the line held none.
    public var uif: Int?

    public init(serial: String, slot: Int, uif: Int?) {
        self.serial = serial
        self.slot = slot
        self.uif = uif
    }
}

/// Card serial numbers that peers report.
public enum CardSerial {
    /// The longest serial scdaemon reports: an OpenPGP application ID has 32 hex digits.
    public static let maxLength = 32

    /// Whether `serial` is what scdaemon reports for a card: 1 to 32 ASCII hex digits. A serial reaches
    /// the host, `cards.conf`, an Assuan command line and the log, so nothing else is accepted.
    public static func isValid(_ serial: String) -> Bool {
        (1...maxLength).contains(serial.utf8.count) && serial.utf8.allSatisfy(isHexDigit)
    }

    /// Whether `serial` is a valid OpenPGP application ID: 32 hex digits that start with D276000124.
    public static func isOpenPGP(_ serial: String) -> Bool {
        serial.utf8.count == 32 && isValid(serial) && serial.uppercased().hasPrefix("D276000124")
    }

    static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// The value of an `S UIF-<n>` status line.
public enum UIFValue {
    /// The first byte of a UIF status value as scdaemon escapes it: `%XX` for a control byte, `+`, `"` or
    /// `%`, `+` for a space, any other byte as itself. Nil for an empty or malformed value, or one that
    /// starts with a byte above 0x7F, which no policy uses.
    public static func firstByte(_ escaped: String) -> UInt8? {
        let bytes = Array(escaped.utf8)
        guard let first = bytes.first else { return nil }
        switch first {
        case UInt8(ascii: "%"):
            guard bytes.count >= 3, CardSerial.isHexDigit(bytes[1]), CardSerial.isHexDigit(bytes[2]),
                  let value = UInt8(String(decoding: bytes[1...2], as: UTF8.self), radix: 16) else { return nil }
            return value
        case UInt8(ascii: "+"):
            return 0x20
        case 0x21...0x7E:
            return first
        default:
            return nil
        }
    }
}

// MARK: Pinentry requests

/// Fields that scdaemon puts in a card PIN description, separated by RS and US bytes.
public struct CardFields: Codable, Sendable, Equatable {
    public var number: String?
    public var holder: String?
    public var counter: String?

    public init(number: String? = nil, holder: String? = nil, counter: String? = nil) {
        self.number = number
        self.holder = holder
        self.counter = counter
    }
}

public struct GetPin: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    /// Description with percent-escapes decoded and RS/US separators removed.
    public var desc: String?
    public var prompt: String?
    /// Parsed card fields, when the description carries them.
    public var fields: CardFields?
    /// Error text from SETERROR, shown above the field on a retry.
    public var error: String?
    public var ok: String?
    public var cancel: String?
    /// The SETKEYINFO value, or nil when cleared.
    public var keyinfo: String?
    /// The agent's OPTION owner value: "<client pid>/<uid> <hostname>".
    public var owner: String?

    public init(id: String, title: String? = nil, desc: String? = nil, prompt: String? = nil, fields: CardFields? = nil, error: String? = nil, ok: String? = nil, cancel: String? = nil, keyinfo: String? = nil, owner: String? = nil) {
        self.id = id
        self.title = title
        self.desc = desc
        self.prompt = prompt
        self.fields = fields
        self.error = error
        self.ok = ok
        self.cancel = cancel
        self.keyinfo = keyinfo
        self.owner = owner
    }
}

public struct Confirm: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var desc: String?
    public var ok: String?
    public var cancel: String?
    /// Label of a third "no" button; when set, the host can answer notConfirmed.
    public var notok: String?
    public var oneButton: Bool
    public var owner: String?

    public init(id: String, title: String? = nil, desc: String? = nil, ok: String? = nil, cancel: String? = nil, notok: String? = nil, oneButton: Bool = false, owner: String? = nil) {
        self.id = id
        self.title = title
        self.desc = desc
        self.ok = ok
        self.cancel = cancel
        self.notok = notok
        self.oneButton = oneButton
        self.owner = owner
    }

    enum CodingKeys: String, CodingKey {
        case id, title, desc, ok, cancel, notok, owner
        case oneButton = "one_button"
    }
}

public struct MessageRequest: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var desc: String?
    public var ok: String?

    public init(id: String, title: String? = nil, desc: String? = nil, ok: String? = nil) {
        self.id = id
        self.title = title
        self.desc = desc
        self.ok = ok
    }
}

public struct RequestRef: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct Ping: Codable, Sendable, Equatable {
    public var seq: Int

    public init(seq: Int) {
        self.seq = seq
    }
}

// MARK: Host replies

/// The entered PIN or passphrase. Its description is redacted so that printing or logging the value never shows the secret.
public struct PinReply: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var id: String
    /// UTF-8 bytes of the secret, base64 on the wire.
    public var secret: Data

    public init(id: String, secret: Data) {
        self.id = id
        self.secret = secret
    }

    public var description: String { "PinReply(id: \(id), secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "secret": "<redacted>"]) }

    enum CodingKeys: String, CodingKey {
        case id
        case secret = "secret_b64"
    }
}

// MARK: Envelope

public enum IPCMessage: Sendable, Equatable {
    case hello(Hello)

    case opStart(OpStart)
    case pinNeeded(ConnRef)
    case pinSent(ConnRef)
    case touchWait(TouchWait)
    case opEnd(OpEnd)
    case touchPolicy(TouchPolicyReport)

    case getPin(GetPin)
    case confirm(Confirm)
    case message(MessageRequest)
    /// The pinentry no longer needs the request's panel: the agent sent BYE or a signal, or the request timed out.
    case dismiss(RequestRef)
    case ping(Ping)

    case pin(PinReply)
    /// The user pressed OK on a confirm or message.
    case confirmed(RequestRef)
    /// The user pressed the "no" button of a confirm.
    case notConfirmed(RequestRef)
    case cancelled(RequestRef)
    /// The host can't show this request; the pinentry hands it to pinentry-mac.
    case fallback(RequestRef)
    case pong(Ping)

    /// A message type this version does not know. Receivers ignore it.
    case unknown(type: String)

    /// The wire value of the "type" field.
    public var type: String {
        switch self {
        case .hello: "hello"
        case .opStart: "op_start"
        case .pinNeeded: "pin_needed"
        case .pinSent: "pin_sent"
        case .touchWait: "touch_wait"
        case .opEnd: "op_end"
        case .touchPolicy: "touch_policy"
        case .getPin: "getpin"
        case .confirm: "confirm"
        case .message: "message"
        case .dismiss: "dismiss"
        case .ping: "ping"
        case .pin: "pin"
        case .confirmed: "confirmed"
        case .notConfirmed: "not_confirmed"
        case .cancelled: "cancelled"
        case .fallback: "fallback"
        case .pong: "pong"
        case .unknown(let type): type
        }
    }

    /// The request ID for pinentry requests and host replies.
    public var requestID: String? {
        switch self {
        case .getPin(let m): m.id
        case .confirm(let m): m.id
        case .message(let m): m.id
        case .pin(let m): m.id
        case .dismiss(let r), .confirmed(let r), .notConfirmed(let r), .cancelled(let r), .fallback(let r): r.id
        default: nil
        }
    }
}

extension IPCMessage: Codable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "op_start": self = .opStart(try OpStart(from: decoder))
        case "pin_needed": self = .pinNeeded(try ConnRef(from: decoder))
        case "pin_sent": self = .pinSent(try ConnRef(from: decoder))
        case "touch_wait": self = .touchWait(try TouchWait(from: decoder))
        case "op_end": self = .opEnd(try OpEnd(from: decoder))
        case "touch_policy": self = .touchPolicy(try TouchPolicyReport(from: decoder))
        case "getpin": self = .getPin(try GetPin(from: decoder))
        case "confirm": self = .confirm(try Confirm(from: decoder))
        case "message": self = .message(try MessageRequest(from: decoder))
        case "dismiss": self = .dismiss(try RequestRef(from: decoder))
        case "ping": self = .ping(try Ping(from: decoder))
        case "pin": self = .pin(try PinReply(from: decoder))
        case "confirmed": self = .confirmed(try RequestRef(from: decoder))
        case "not_confirmed": self = .notConfirmed(try RequestRef(from: decoder))
        case "cancelled": self = .cancelled(try RequestRef(from: decoder))
        case "fallback": self = .fallback(try RequestRef(from: decoder))
        case "pong": self = .pong(try Ping(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .opStart(let m): try m.encode(to: encoder)
        case .pinNeeded(let m), .pinSent(let m): try m.encode(to: encoder)
        case .touchWait(let m): try m.encode(to: encoder)
        case .opEnd(let m): try m.encode(to: encoder)
        case .touchPolicy(let m): try m.encode(to: encoder)
        case .getPin(let m): try m.encode(to: encoder)
        case .confirm(let m): try m.encode(to: encoder)
        case .message(let m): try m.encode(to: encoder)
        case .dismiss(let m), .confirmed(let m), .notConfirmed(let m), .cancelled(let m), .fallback(let m): try m.encode(to: encoder)
        case .ping(let m), .pong(let m): try m.encode(to: encoder)
        case .pin(let m): try m.encode(to: encoder)
        case .unknown: break
        }
    }
}

public enum IPCProtocol {
    /// Version string sent in hello, for logs; no peer checks it. Messages stay compatible in both
    /// directions instead: new fields are optional and receivers ignore unknown message types. Which
    /// release a helper belongs to travels in `Hello.build`.
    public static let version = "1"
}
