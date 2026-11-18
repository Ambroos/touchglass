import Darwin
import Foundation
import TouchGlassIPC

/// Sends events to the host socket from a dedicated thread, dropping them when the host is slow or absent.
///
/// `send(_:)` only appends to a bounded queue. The writer thread connects lazily, writes each line with a
/// short deadline and closes the connection when the host stops reading, so a stopped host costs at most
/// that deadline per event and never touches the forwarding threads.
///
/// When the host is down at an `op_start`, the writer starts it through `launchHost`, at most once per
/// `launchInterval`, and waits up to `launchWait` for it to listen, so the touch wait that follows still
/// reaches it.
public final class HostEventSink: EventSink, @unchecked Sendable {
    public static let queueCapacity = 64
    /// How long one line may take to write before the connection is dropped.
    public static let writeDeadline: TimeInterval = 0.2
    /// Events older than this when the writer gets to them are dropped instead of sent.
    public static let maxEventAge: TimeInterval = 2
    /// The shortest time between two attempts to start the host.
    public static let launchInterval: TimeInterval = 10
    /// How long the writer waits for a host it started to accept connections.
    public static let launchWait: TimeInterval = 2

    private struct Item {
        var line: Data
        var queuedAt: Double
        var startsOperation: Bool
    }

    private let path: String
    private let launchHost: (@Sendable () -> Bool)?
    private let condition = NSCondition()
    private var queue: [Item] = []
    private var busy = false
    // Used only on the writer thread.
    private var connection: IPCConnection?
    private var lastLaunch = -Double.infinity
    /// Counts events dropped because the queue was full, for tests.
    public private(set) var droppedCount = 0

    /// - Parameter launchHost: Starts the host app and returns whether the attempt began. Nil never starts it.
    public init(path: String = IPCPaths.hostSocket, launchHost: (@Sendable () -> Bool)? = nil) {
        self.path = path
        self.launchHost = launchHost
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "touchglass.scdaemon.host"
        thread.start()
    }

    public func send(_ message: IPCMessage) {
        guard let line = try? IPCLine.encode(message) else { return }
        let startsOperation = if case .opStart = message { true } else { false }
        condition.lock()
        if queue.count >= Self.queueCapacity {
            droppedCount += 1
        } else {
            queue.append(Item(line: line, queuedAt: Posix.monotonicSeconds(), startsOperation: startsOperation))
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
                deliver(item)
            }

            condition.lock()
            busy = false
            condition.broadcast()
            condition.unlock()
        }
    }

    private func deliver(_ item: Item) {
        if let connection {
            if write(item.line, to: connection) { return }
            // The host restarted or stopped reading. The first write after a restart fails with EPIPE, so
            // reconnect once and resend this event instead of losing it.
            dropConnection()
        }
        guard let fresh = connect(launching: item.startsOperation) else { return }
        if !write(item.line, to: fresh) { dropConnection() }
    }

    /// Connects and says hello. Starts the host first when `launching` allows it and it is not running.
    private func connect(launching: Bool) -> IPCConnection? {
        if let fresh = openConnection() { return fresh }
        let now = Posix.monotonicSeconds()
        guard launching, let launchHost, now - lastLaunch >= Self.launchInterval else { return nil }
        lastLaunch = now
        guard launchHost() else { return nil }
        while Posix.monotonicSeconds() - now < Self.launchWait {
            usleep(50_000)
            if let fresh = openConnection() { return fresh }
        }
        return nil
    }

    private func openConnection() -> IPCConnection? {
        guard let fresh = try? IPCClient.connect(path: path, timeout: 0.1),
              let hello = try? IPCLine.encode(.hello(Hello(role: .proxy)))
        else { return nil }
        Posix.setNonBlocking(fresh.fileDescriptor, true)
        guard write(hello, to: fresh) else {
            fresh.close()
            return nil
        }
        connection = fresh
        return fresh
    }

    private func dropConnection() {
        connection?.close()
        connection = nil
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
