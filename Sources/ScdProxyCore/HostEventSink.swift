import Darwin
import Foundation
import TouchGlassIPC

/// Sends events to the host socket from a dedicated thread, dropping them when the host is slow or absent.
///
/// `send(_:)` only appends to a bounded queue. The writer thread connects lazily, writes each line with a
/// short deadline and closes the connection when the host stops reading, so a stopped host costs at most
/// that deadline per event and never touches the forwarding threads.
public final class HostEventSink: EventSink, @unchecked Sendable {
    public static let queueCapacity = 64
    /// How long one line may take to write before the connection is dropped.
    public static let writeDeadline: TimeInterval = 0.2
    /// Events older than this when the writer gets to them are dropped instead of sent.
    public static let maxEventAge: TimeInterval = 2

    private let path: String
    private let condition = NSCondition()
    private var queue: [(line: Data, queuedAt: Double)] = []
    private var busy = false
    private var connection: IPCConnection?
    /// Counts events dropped because the queue was full, for tests.
    public private(set) var droppedCount = 0

    public init(path: String = IPCPaths.hostSocket) {
        self.path = path
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "touchglass.scdaemon.host"
        thread.start()
    }

    public func send(_ message: IPCMessage) {
        guard let line = try? IPCLine.encode(message) else { return }
        condition.lock()
        if queue.count >= Self.queueCapacity {
            droppedCount += 1
        } else {
            queue.append((line, Posix.monotonicSeconds()))
            condition.signal()
        }
        condition.unlock()
    }

    /// Waits up to `timeout` for queued events to be written or dropped.
    public func flush(timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while (!queue.isEmpty || busy) && condition.wait(until: deadline) {}
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while queue.isEmpty { condition.wait() }
            let item = queue.removeFirst()
            busy = true
            condition.unlock()

            if Posix.monotonicSeconds() - item.queuedAt <= Self.maxEventAge {
                deliver(item.line)
            }

            condition.lock()
            busy = false
            condition.broadcast()
            condition.unlock()
        }
    }

    private func deliver(_ line: Data) {
        if connection == nil {
            guard let fresh = try? IPCClient.connect(path: path, timeout: 0.1) else { return }
            Posix.setNonBlocking(fresh.fileDescriptor, true)
            connection = fresh
            if !write(.hello(Hello(role: .proxy)), to: fresh) { return }
        }
        guard let connection else { return }
        if !write(line, to: connection) {
            connection.close()
            self.connection = nil
        }
    }

    private func write(_ message: IPCMessage, to connection: IPCConnection) -> Bool {
        guard let line = try? IPCLine.encode(message) else { return false }
        if write(line, to: connection) { return true }
        connection.close()
        self.connection = nil
        return false
    }

    /// Writes the whole line before the deadline, or returns false. A partly written line leaves the stream
    /// unusable, so the caller closes the connection on failure.
    private func write(_ line: Data, to connection: IPCConnection) -> Bool {
        let fd = connection.fileDescriptor
        let deadline = Posix.monotonicSeconds() + Self.writeDeadline
        return line.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                guard n < 0 && errno == EAGAIN else { return false }
                let remaining = deadline - Posix.monotonicSeconds()
                guard remaining > 0 else { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(remaining * 1000) + 1) <= 0 { return false }
            }
            return true
        }
    }
}
