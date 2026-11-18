import Darwin
import Foundation
import TouchGlassIPC

/// Accepts helper connections on the host socket and reads them on background threads.
///
/// Pings are answered on the reading thread, so a busy main thread never makes a pinentry give
/// up. Every other message, and every closed connection, is delivered to the main queue.
public final class HostServer: @unchecked Sendable {
    public typealias MessageHandler = @MainActor @Sendable (IPCMessage, ConnectionID) -> Void
    public typealias CloseHandler = @MainActor @Sendable (ConnectionID) -> Void

    private let server: IPCServer
    private let lock = NSLock()
    private var connections: [ConnectionID: (connection: IPCConnection, sendQueue: DispatchQueue)] = [:]
    private var nextID: ConnectionID = 1
    private var stopped = false
    private var onMessage: MessageHandler = { _, _ in }
    private var onClose: CloseHandler = { _ in }

    /// Listens on `path`. Throws `IPCError.addressInUse` if another host answers there.
    public init(path: String = IPCPaths.hostSocket) throws {
        server = try IPCServer(path: path)
    }

    public var path: String { server.path }

    public func start(onMessage: @escaping MessageHandler, onClose: @escaping CloseHandler) {
        lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "TouchGlass accept"
        thread.start()
    }

    public func stop() {
        let open = lock.withLock {
            stopped = true
            return connections.values.map(\.connection)
        }
        server.close()
        open.forEach { $0.close() }
    }

    /// Sends a message to a connection, in order with its other sends. Drops it if the connection is gone.
    public func send(_ message: IPCMessage, to id: ConnectionID) {
        guard let entry = lock.withLock({ connections[id] }) else { return }
        entry.sendQueue.async { try? entry.connection.send(message) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        while !isStopped {
            var pfd = pollfd(fd: server.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 250) > 0, !isStopped, let connection = try? server.accept() else { continue }
            let id = lock.withLock {
                let id = nextID
                nextID += 1
                connections[id] = (connection, DispatchQueue(label: "TouchGlass send \(id)"))
                return id
            }
            let thread = Thread { [self] in readLoop(id, connection) }
            thread.name = "TouchGlass connection \(id)"
            thread.start()
        }
    }

    private func readLoop(_ id: ConnectionID, _ connection: IPCConnection) {
        let (handler, closeHandler) = lock.withLock { (onMessage, onClose) }
        while !isStopped {
            let message: IPCMessage
            do {
                guard let next = try connection.receive(timeout: 0.25) else { continue }
                message = next
            } catch {
                break
            }
            if case .ping(let ping) = message {
                send(.pong(ping), to: id)
                continue
            }
            DispatchQueue.main.async { handler(message, id) }
        }
        let entry = lock.withLock { connections.removeValue(forKey: id) }
        // Let queued sends finish before closing.
        entry?.sendQueue.async { connection.close() }
        DispatchQueue.main.async { closeHandler(id) }
    }
}
