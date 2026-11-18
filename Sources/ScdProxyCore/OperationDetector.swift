import Dispatch
import Foundation
import TouchGlassIPC

/// Receives the events that the detector produces.
public protocol EventSink: Sendable {
    /// Must return without blocking.
    func send(_ message: IPCMessage)
}

/// Turns the classified lines of each connection into card operation events for the host.
///
/// Rules, per connection:
/// - `S KEYINFO <grip> T <serial> OPENPGP.<n> …` maps a keygrip to its slot and card serial.
/// - `PKSIGN`, `PKAUTH` or `PKDECRYPT <grip>` starts an operation. `PKSIGN` with the slot 3 grip runs as an
///   authentication, so it reports `auth`.
/// - `INQUIRE NEEDPIN` means the agent asks for the PIN; the agent's `END` means it sent one.
/// - The card signals nothing while it waits for a touch. When an operation is outstanding, no inquiry is
///   open, and `touchDelay` passes after the operation command, the last inquiry answer or
///   `S PINCACHE_PUT`, the detector reports a touch wait.
/// - `OK` or `ERR` ends the operation.
///
/// All state lives on one serial queue, so the forwarding threads only enqueue and never wait.
public final class OperationDetector: @unchecked Sendable {
    /// The card's touch timeout that the host counts down from.
    public static let touchTimeoutMs = 15_000

    private let queue = DispatchQueue(label: "touchglass.scdaemon.detector")
    private let sink: EventSink
    private let touchDelay: TimeInterval

    // Accessed only on `queue`.
    private var keys: [String: (slot: Int, serial: String)] = [:]
    private var connections: [String: ConnectionState] = [:]

    private enum Inquiry {
        case needPin
        case other
    }

    private struct Operation {
        var touchArmedAt: Double = 0
        var timerGeneration = 0
        var touchReported = false
    }

    private struct ConnectionState {
        var operation: Operation?
        var inquiry: Inquiry?
    }

    public init(sink: EventSink, touchDelay: TimeInterval = 0.4) {
        self.sink = sink
        self.touchDelay = touchDelay
    }

    /// Handles lines seen on `connection`. `time` is when the forwarding thread passed them on, in Unix seconds.
    public func observe(connection: String, direction: StreamDirection, lines: [WireLine], time: Double) {
        guard !lines.isEmpty else { return }
        queue.async {
            for line in lines {
                switch direction {
                case .toServer: self.clientLine(connection, line, time)
                case .toClient: self.serverLine(connection, line, time)
                }
            }
        }
    }

    /// Ends any open operation on `connection` and forgets it.
    public func closed(connection: String) {
        queue.async {
            if self.connections[connection]?.operation != nil {
                self.sink.send(.opEnd(OpEnd(conn: connection, result: .error)))
            }
            self.connections[connection] = nil
        }
    }

    /// Waits until every event observed so far has been handled. For tests and shutdown.
    public func drain() {
        queue.sync {}
    }

    private func clientLine(_ conn: String, _ line: WireLine, _ time: Double) {
        var state = connections[conn] ?? ConnectionState()
        defer { connections[conn] = state }

        switch line {
        case let .command(keyword, args):
            guard ["PKSIGN", "PKAUTH", "PKDECRYPT"].contains(keyword) else {
                state.inquiry = nil
                return
            }
            if state.operation != nil {
                // The agent never sends a second command while one is outstanding; treat it as the end of the first.
                sink.send(.opEnd(OpEnd(conn: conn, result: .error)))
            }
            let grip = args.last { !$0.hasPrefix("--") }?.uppercased()
            let key = grip.flatMap { keys[$0] }
            let kind: OperationKind
            switch keyword {
            case "PKSIGN": kind = key?.slot == 3 ? .auth : .sign
            case "PKAUTH": kind = .auth
            default: kind = .decrypt
            }
            sink.send(.opStart(OpStart(conn: conn, op: kind, slot: key?.slot, serial: key?.serial, at: time)))
            state.operation = Operation()
            state.inquiry = nil
            armTouchTimer(conn, &state, from: time)

        case .end:
            if state.inquiry == .needPin {
                sink.send(.pinSent(ConnRef(conn: conn)))
            }
            if state.inquiry != nil {
                state.inquiry = nil
                armTouchTimer(conn, &state, from: time)
            }

        case .cancel:
            state.inquiry = nil

        case .data, .comment, .other, .ok, .err, .status, .inquire:
            break
        }
    }

    private func serverLine(_ conn: String, _ line: WireLine, _ time: Double) {
        var state = connections[conn] ?? ConnectionState()
        defer { connections[conn] = state }

        switch line {
        case let .status(keyword, args):
            if keyword == "KEYINFO" {
                recordKeyInfo(args)
            } else if keyword == "PINCACHE_PUT", state.operation?.touchReported == false {
                // scdaemon caches the PIN right after the card accepted it; the card operation starts next.
                armTouchTimer(conn, &state, from: time)
            }

        case let .inquire(keyword, args):
            guard state.operation != nil else { return }
            state.operation?.timerGeneration += 1
            switch keyword {
            case "NEEDPIN":
                state.inquiry = .needPin
                sink.send(.pinNeeded(ConnRef(conn: conn)))
            case "POPUPPINPADPROMPT" where args.first == "--ack":
                // gnupg's own touch prompt, sent by some CCID readers. When it appears it is an exact signal.
                state.inquiry = .other
                if state.operation?.touchReported == false {
                    state.operation?.touchReported = true
                    sink.send(.touchWait(TouchWait(conn: conn, timeoutMs: Self.touchTimeoutMs, at: time)))
                }
            default:
                state.inquiry = .other
            }

        case .ok:
            if state.operation != nil {
                sink.send(.opEnd(OpEnd(conn: conn, result: .ok)))
            }
            state.operation = nil
            state.inquiry = nil

        case let .err(code):
            if state.operation != nil {
                sink.send(.opEnd(OpEnd(conn: conn, result: Self.result(forErrorCode: code), code: code)))
            }
            state.operation = nil
            state.inquiry = nil

        case .command, .data, .end, .cancel, .comment, .other:
            break
        }
    }

    private func recordKeyInfo(_ args: [String]) {
        // <grip> T <serial> OPENPGP.<n> <usage>
        guard args.count >= 4, args[1] == "T" else { return }
        let ref = args[3].uppercased()
        guard ref.hasPrefix("OPENPGP."), let slot = Int(ref.dropFirst("OPENPGP.".count)) else { return }
        keys[args[0].uppercased()] = (slot, args[2])
    }

    private func armTouchTimer(_ conn: String, _ state: inout ConnectionState, from time: Double) {
        guard var operation = state.operation, !operation.touchReported else { return }
        operation.timerGeneration += 1
        operation.touchArmedAt = time
        state.operation = operation
        let generation = operation.timerGeneration
        let delay = max(0, touchDelay - (Date().timeIntervalSince1970 - time))
        queue.asyncAfter(deadline: .now() + delay) {
            guard var state = self.connections[conn], var operation = state.operation,
                  operation.timerGeneration == generation, state.inquiry == nil, !operation.touchReported
            else { return }
            operation.touchReported = true
            state.operation = operation
            self.connections[conn] = state
            self.sink.send(.touchWait(TouchWait(conn: conn, timeoutMs: Self.touchTimeoutMs, at: operation.touchArmedAt)))
        }
    }

    /// Maps a gpg-error value from an `ERR` line to the result the host shows.
    public static func result(forErrorCode code: Int?) -> OperationResult {
        guard let code else { return .error }
        switch code & 0xFFFF {
        case 87: return .badPin // GPG_ERR_BAD_PIN
        case 62: return .timeout // GPG_ERR_TIMEOUT
        case 99, 198, 277: return .cancelled // CANCELED, FULLY_CANCELED, ASS_CANCELED
        default: return .error
        }
    }
}
