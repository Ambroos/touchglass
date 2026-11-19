import Darwin
import Foundation
import TouchGlassIPC

/// A stand-in for the TouchGlass host: listens on the host socket and collects the messages it receives.
public final class FakeHost: @unchecked Sendable {
    public let path: String
    private let server: IPCServer
    private let condition = NSCondition()
    private var collected: [IPCMessage] = []
    private var collectedHellos: [Hello] = []
    private var accepted: [Int32] = []
    private let onMessage: (@Sendable (IPCMessage) -> Void)?

    /// Starts listening at `path` and accepting connections on a background thread.
    public init(path: String, onMessage: (@Sendable (IPCMessage) -> Void)? = nil) throws {
        self.path = path
        self.onMessage = onMessage
        server = try IPCServer(path: path)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public func close() {
        server.close()
    }

    /// Shuts down every open accepted connection, as a host that quits does. Call after `close()`.
    public func dropConnections() {
        // Holds the lock across the shutdowns: a connection thread removes its descriptor under the lock
        // before closing it, so none of these numbers can belong to another test yet.
        condition.lock()
        defer { condition.unlock() }
        for fd in accepted { shutdown(fd, SHUT_RDWR) }
    }

    /// Every message received so far, excluding `hello`.
    public var messages: [IPCMessage] {
        condition.lock()
        defer { condition.unlock() }
        return collected
    }

    /// Every hello received so far.
    public var hellos: [Hello] {
        condition.lock()
        defer { condition.unlock() }
        return collectedHellos
    }

    /// Waits until at least `count` messages have arrived or `timeout` passes, then returns all of them.
    @discardableResult
    public func waitForMessages(count: Int, timeout: TimeInterval = 5) -> [IPCMessage] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while collected.count < count && condition.wait(until: deadline) {}
        return collected
    }

    /// Waits until a message satisfies `predicate`, then returns all messages so far.
    @discardableResult
    public func waitFor(timeout: TimeInterval = 5, _ predicate: (IPCMessage) -> Bool) -> [IPCMessage] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !collected.contains(where: predicate) && condition.wait(until: deadline) {}
        return collected
    }

    private func acceptLoop() {
        while let accepted = try? server.accept() {
            nonisolated(unsafe) let connection = accepted
            condition.lock()
            self.accepted.append(connection.fileDescriptor)
            condition.unlock()
            Thread.detachNewThread { [self] in
                defer {
                    condition.lock()
                    self.accepted.removeAll { $0 == connection.fileDescriptor }
                    connection.close()
                    condition.unlock()
                }
                while let message = try? connection.receive() {
                    if case .hello(let hello) = message {
                        condition.lock()
                        collectedHellos.append(hello)
                        condition.unlock()
                        continue
                    }
                    onMessage?(message)
                    condition.lock()
                    collected.append(message)
                    condition.broadcast()
                    condition.unlock()
                }
            }
        }
    }
}

extension IPCMessage {
    /// A compact form for assertions: the type plus the fields that matter, without the timestamps and the
    /// process ID in the connection name.
    public var summary: String {
        func shortConn(_ conn: String) -> String { conn.split(separator: ":").last.map(String.init) ?? conn }
        switch self {
        case let .opStart(m):
            return "op_start \(shortConn(m.conn)) \(m.op.rawValue) slot=\(m.slot.map(String.init) ?? "-")"
        case let .pinNeeded(m): return "pin_needed \(shortConn(m.conn))"
        case let .pinSent(m): return "pin_sent \(shortConn(m.conn))"
        case let .touchWait(m): return "touch_wait \(shortConn(m.conn))"
        case let .opEnd(m): return "op_end \(shortConn(m.conn)) \(m.result.rawValue)"
        case let .touchPolicy(m): return "touch_policy \(m.serial) slot=\(m.slot) uif=\(m.uif.map(String.init) ?? "-")"
        default: return type
        }
    }
}
