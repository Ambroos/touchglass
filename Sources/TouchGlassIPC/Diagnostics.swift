import Darwin
import Foundation
import os
import Synchronization

/// The unified log category of each component.
public enum LogCategory: String, Sendable {
    case scdaemon
    case host
    case pinentry
}

/// A command that gpg-agent sends to scdaemon, as the log names it. Only these keywords reach the log;
/// anything else is `other`, so a line from the stream can never become log text.
public enum ScdCommand: String, Sendable, Equatable, CaseIterable {
    case serialno = "SERIALNO"
    case keyinfo = "KEYINFO"
    case setdata = "SETDATA"
    case pksign = "PKSIGN"
    case pkauth = "PKAUTH"
    case pkdecrypt = "PKDECRYPT"
    case getinfo = "GETINFO"
    case getattr = "GETATTR"
    case learn = "LEARN"
    case readkey = "READKEY"
    case checkpin = "CHECKPIN"
    case restart = "RESTART"
    case switchcard = "SWITCHCARD"
    case option = "OPTION"
    case devinfo = "DEVINFO"
    case bye = "BYE"
    case other

    public init(keyword: String) {
        self = ScdCommand(rawValue: keyword.uppercased()) ?? .other
    }
}

/// A panel state, by name only.
public enum PanelStateName: String, Sendable, Equatable {
    case pinEntry = "pin-entry"
    case verifying
    case passphrase
    case touchWait = "touch-wait"
    case success
    case failure
    case confirm
    case message
}

/// Why the panel asked for key status, for the log.
public enum PanelKeyReason: String, Sendable, Equatable {
    /// The entrance of a prompt started.
    case open
    /// A state change on the visible panel, such as a prompt replacing a lingering state.
    case setKey = "set-key"
    /// The panel lost key status within half a second of its own content change and took it back.
    case retake = "re-take after own change"
    /// A prompt arrived during the exit animation, which turned around.
    case reverseClose = "reverse close"
}

/// Something worth a line in the unified log.
///
/// Log calls take only these events, and each case carries only typed, non-secret values: operation kinds,
/// results, the last 4 digits of card serials, connection IDs, releases, durations and the bundle IDs of
/// frontmost apps. Connection IDs and releases that come from socket peers are checked before they are
/// logged. No case takes a line from the Assuan stream, a PIN, a passphrase, hash data or a `D` payload.
public enum LogEvent: Sendable, Equatable {
    // touchglass-scdaemon
    case proxyStarted(scdaemonPID: Int32, relaySocket: Bool)
    case scdaemonExited(status: Int32)
    case cardCommand(conn: String, command: ScdCommand, ok: Bool, duration: TimeInterval)
    case operationStarted(conn: String, kind: OperationKind, slot: Int?, serial: String?)
    case pinRequested(conn: String)
    case pinAnswered(conn: String)
    /// `delay` is the detection delay that passed since `armed`, the operation command or the last inquiry answer.
    case touchWaitInferred(conn: String, delay: TimeInterval, pinpadPrompt: Bool)
    /// `total` runs from the operation command, `sinceArmed` from the command or the last inquiry answer, which
    /// is what the touch detection delay measures.
    case operationEnded(conn: String, kind: OperationKind, result: OperationResult, code: Int?, total: TimeInterval, sinceArmed: TimeInterval, touchWaitReported: Bool)
    /// An `S UIF-<slot>` line named the touch policy of a card's slot; `uif` is its first byte.
    case touchPolicySeen(conn: String, serial: String, slot: Int, uif: Int?)
    case hostConnected(build: String?)
    case hostLaunch(started: Bool)
    case hostUnreachable
    case eventDropped(queueFull: Bool)

    // touchglass-pinentry and touchglass-scdaemon
    /// The helper found the launchers or the command copy out of date and started `touchglass refresh-launchers`,
    /// or failed to start it.
    case launcherRefresh(LauncherRefreshReason, started: Bool)

    // TouchGlass host
    /// `touchCache` is nil for `auto`.
    case hostStarted(version: String?, touchTimeout: TimeInterval?, touchCache: TimeInterval?)
    case connectionOpened(id: Int)
    case connectionClosed(id: Int)
    case hello(id: Int, role: PeerRole, build: String?)
    case retireDecision(hostVersion: String, helperBuild: String)
    case retireExit
    case touchCacheRestarted(serial: String, seconds: TimeInterval)
    case touchDeferred(conn: String, serial: String, showIn: TimeInterval, sinceCommand: TimeInterval)
    case touchShown(conn: String, sinceCommand: TimeInterval, deferred: Bool)
    case touchQueued(conn: String)
    case touchSkipped(conn: String, result: OperationResult)
    /// The card's slot has no touch policy, so the host holds an inferred touch wait back.
    case touchDeferredNoTouchPolicy(conn: String, serial: String, slot: Int, showIn: TimeInterval)
    /// The host asks gpg-agent for a card's touch policies.
    case touchPolicyQuery(serial: String)
    case touchPolicyQueryFailed(serial: String)
    /// The host stored new touch policies for a card; `policies` names them per slot, such as "sign cached".
    case touchPolicyLearned(serial: String, policies: String)
    case panelShow(PanelStateName)
    case panelDismiss
    case panelUserClosed
    case panelUserHid
    /// The panel asked for key status in `state`; `isKey` is whether it has it afterwards. The bundle IDs are
    /// the frontmost app's before and after.
    case panelKeyTaken(state: PanelStateName?, reason: PanelKeyReason, isKey: Bool, frontmostBefore: String?, frontmostAfter: String?)
    /// The panel gave key status back to the frontmost app.
    case panelKeyReleased(state: PanelStateName?, isKey: Bool, frontmostBefore: String?, frontmostAfter: String?)
    /// The panel lost key status within the re-take window, but its state may not hold key, so it left it.
    case panelKeyRetakeSkipped(state: PanelStateName?)
    /// The exit animation ended and ordered the panel out while it still had key status.
    case panelOrderedOutWhileKey(state: PanelStateName?)

    // touchglass-pinentry
    /// A line of the pinentry's diagnostic trace: fixed text, Assuan keywords, message types, request IDs and
    /// paths. The pinentry writes the PIN only as "[redacted]".
    case pinentryTrace(String)

    public var level: OSLogType {
        switch self {
        case .cardCommand, .panelUserHid: .debug
        // Each Assuan keyword and host message the pinentry passes on; the rest is connection and fallback news.
        case .pinentryTrace(let text) where text.hasPrefix("<- ") || text.hasPrefix("-> "): .debug
        case .hostUnreachable, .eventDropped: .default
        default: .info
        }
    }

    public var message: String {
        switch self {
        case let .proxyStarted(pid, relay):
            return "proxy started: scdaemon pid \(pid), relay socket \(relay ? "on" : "off")"
        case let .scdaemonExited(status):
            return "scdaemon exited: status \(status)"
        case let .cardCommand(conn, command, ok, duration):
            return "\(Self.conn(conn)) \(command.rawValue) \(ok ? "OK" : "ERR") in \(Self.ms(duration))"
        case let .operationStarted(conn, kind, slot, serial):
            return "\(Self.conn(conn)) op start: \(kind.rawValue) slot \(slot.map(String.init) ?? "?") card \(Self.card(serial))"
        case let .pinRequested(conn):
            return "\(Self.conn(conn)) PIN requested"
        case let .pinAnswered(conn):
            return "\(Self.conn(conn)) PIN answered"
        case let .touchWaitInferred(conn, delay, pinpad):
            return pinpad ? "\(Self.conn(conn)) touch wait: pinpad prompt" : "\(Self.conn(conn)) touch wait inferred after \(Self.ms(delay)) of silence"
        case let .operationEnded(conn, kind, result, code, total, sinceArmed, reported):
            let codeText = code.map { " code \($0)" } ?? ""
            return "\(Self.conn(conn)) op end: \(kind.rawValue) \(result.rawValue)\(codeText), card \(Self.ms(sinceArmed)) since command or PIN, total \(Self.ms(total)), touch wait \(reported ? "reported" : "not reported")"
        case let .touchPolicySeen(conn, serial, slot, uif):
            return "\(Self.conn(conn)) touch policy: card \(Self.card(serial)) slot \(slot) UIF \(uif.map { String(format: "%02X", $0) } ?? "?")"
        case let .hostConnected(build):
            return "connected to host" + (build.map { ", reported release \(Self.release($0))" } ?? "")
        case let .hostLaunch(started):
            return started ? "host not running: starting it" : "host not running: start failed"
        case .hostUnreachable:
            return "host unreachable: event dropped"
        case let .eventDropped(queueFull):
            return queueFull ? "event queue full: event dropped" : "event too old: dropped"
        case let .launcherRefresh(reason, started):
            let outcome = started ? "started touchglass refresh-launchers" : "could not start touchglass refresh-launchers"
            switch reason {
            case let .launcherFormat(installed, current):
                return "launchers: format \(installed) is older than \(current): \(outcome)"
            case let .commandRelease(installed, helper):
                return "command copy: release \(installed) is older than helper release \(helper): \(outcome)"
            }
        case let .hostStarted(version, timeout, cache):
            return "host started: release \(version ?? "dev"), touch-timeout \(timeout.map { Self.seconds($0) } ?? "card"), touch-cache \(cache.map { Self.seconds($0) } ?? "auto")"
        case let .connectionOpened(id):
            return "connection \(id) opened"
        case let .connectionClosed(id):
            return "connection \(id) closed"
        case let .hello(id, role, build):
            return "connection \(id) hello: \(role.rawValue)" + (build.map { ", release \(Self.release($0))" } ?? "")
        case let .retireDecision(host, helper):
            return "retiring: helper release \(Self.release(helper)) is newer than host release \(host); exiting when idle"
        case .retireExit:
            return "retiring: idle, exiting"
        case let .touchCacheRestarted(serial, seconds):
            return "touch cache: card \(Self.card(serial)) window restarted, \(Self.seconds(seconds))"
        case let .touchDeferred(conn, serial, showIn, since):
            return "\(Self.conn(conn)) touch wait inside card \(Self.card(serial)) cache window: panel deferred \(Self.ms(showIn)), \(Self.ms(since)) since command"
        case let .touchShown(conn, since, deferred):
            return "\(Self.conn(conn)) touch panel shown \(Self.ms(since)) after command" + (deferred ? " (deferred)" : "")
        case let .touchQueued(conn):
            return "\(Self.conn(conn)) touch wait queued"
        case let .touchSkipped(conn, result):
            return "\(Self.conn(conn)) op ended \(result.rawValue) before its deferred touch panel: nothing shown"
        case let .touchDeferredNoTouchPolicy(conn, serial, slot, showIn):
            return "\(Self.conn(conn)) touch wait on card \(Self.card(serial)) slot \(slot), whose touch policy is off: panel deferred \(Self.ms(showIn))"
        case let .touchPolicyQuery(serial):
            return "touch policy: asking gpg-agent about card \(Self.card(serial))"
        case let .touchPolicyQueryFailed(serial):
            return "touch policy: query for card \(Self.card(serial)) failed"
        case let .touchPolicyLearned(serial, policies):
            return "touch policy: card \(Self.card(serial)) \(policies)"
        case let .panelShow(state):
            return "panel: \(state.rawValue)"
        case .panelDismiss:
            return "panel: dismiss"
        case .panelUserClosed:
            return "panel: closed by user"
        case .panelUserHid:
            return "panel: hidden by user"
        case let .panelKeyTaken(state, reason, isKey, before, after):
            return "panel: make key (\(reason.rawValue)) in \(Self.name(state)): \(isKey ? "key" : "not key"), frontmost \(Self.app(before)) -> \(Self.app(after))"
        case let .panelKeyReleased(state, isKey, before, after):
            return "panel: release key in \(Self.name(state)): \(isKey ? "still key" : "not key"), frontmost \(Self.app(before)) -> \(Self.app(after))"
        case let .panelKeyRetakeSkipped(state):
            return "panel: lost key in \(Self.name(state)), not taking it back"
        case let .panelOrderedOutWhileKey(state):
            return "panel: ordered out while key, after \(Self.name(state))"
        case let .pinentryTrace(text):
            return text
        }
    }

    /// A connection ID as the proxy makes them, `<pid>:p` or `<pid>:s<n>`. The host gets them from socket
    /// peers, so anything else is logged as "?".
    static func conn(_ id: String) -> String {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, isDigits(parts[0]) else { return "?" }
        let session = parts[1]
        if session == "p" || (session.first == "s" && isDigits(session.dropFirst())) { return id }
        return "?"
    }

    /// The last 4 digits of a card's serial: enough to tell cards apart, without the full number in a
    /// sysdiagnose. A full OpenPGP application ID yields the digits of its serial number field.
    static func card(_ serial: String?) -> String {
        guard var serial, !serial.isEmpty else { return "?" }
        if serial.utf8.count == 32, serial.uppercased().hasPrefix("D276000124") {
            serial = String(serial.dropFirst(20).prefix(8))
        }
        let tail = serial.suffix(4)
        return tail.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? "…" + tail : "?"
    }

    /// A release that a socket peer reported: a dotted number, or a build name such as "HEAD-1a2b3c4" of
    /// letters, digits, ".", "+" and "-" only. Anything else is logged as "?", so a peer can't put free text
    /// into a log line.
    static func release(_ build: String) -> String {
        let allowed = build.utf8.count <= 40 && !build.isEmpty && build.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "+" || $0 == "-")
        }
        return allowed ? build : "?"
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func name(_ state: PanelStateName?) -> String {
        state?.rawValue ?? "no state"
    }

    static func app(_ bundleID: String?) -> String {
        bundleID ?? "none"
    }

    static func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    static func seconds(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}

/// Writes `LogEvent`s to the unified log under the subsystem `io.ambroos.touchglass`.
///
/// Read it with `log stream --predicate 'subsystem == "io.ambroos.touchglass"' --level info`; add
/// `--level debug` for every card command.
public struct TouchGlassLog: Sendable {
    public static let subsystem = "io.ambroos.touchglass"
    /// For tests: a file that receives a copy of every line, from every process that inherits the variable.
    public static let mirrorEnvironmentKey = "TOUCHGLASS_LOG_MIRROR"

    private static let mirrorFD = Mutex<Int32>(openMirror(ProcessInfo.processInfo.environment[mirrorEnvironmentKey]))

    public let category: LogCategory
    private let logger: Logger

    public init(_ category: LogCategory) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func callAsFunction(_ event: LogEvent) {
        let message = event.message
        // Every value in `message` is non-secret by construction; see `LogEvent`.
        logger.log(level: event.level, "\(message, privacy: .public)")
        Self.mirrorFD.withLock { fd in
            guard fd >= 0 else { return }
            let bytes = Array("\(category.rawValue)[\(getpid())] \(message)\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// For tests in one process: copies every line from now on to `path`, or stops copying for `nil`.
    public static func mirror(toFile path: String?) {
        mirrorFD.withLock { fd in
            if fd >= 0 { Darwin.close(fd) }
            fd = openMirror(path)
        }
    }

    private static func openMirror(_ path: String?) -> Int32 {
        guard let path, !path.isEmpty else { return -1 }
        return Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    }
}
