import Darwin
import Foundation

public enum IPCPaths {
    /// `~/Library/Application Support/TouchGlass`, created with mode 0700 by the host.
    public static var supportDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/TouchGlass"
    }

    /// The host's listening socket. The `TOUCHGLASS_SOCKET` environment variable overrides it, for tests.
    public static var hostSocket: String {
        if let path = ProcessInfo.processInfo.environment["TOUCHGLASS_SOCKET"], !path.isEmpty {
            return path
        }
        return supportDirectory + "/host.sock"
    }
}

/// One connected Unix socket that carries IPC messages. One thread may send while another receives; two threads must not send, or receive, at the same time.
public final class IPCConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private var reader = IPCLineReader()
    private var pending: [IPCMessage] = []
    private var isClosed = false

    /// Takes ownership of a connected socket.
    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        var on: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
    }

    /// The peer's effective user ID.
    public var peerUID: uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fileDescriptor, &uid, &gid) == 0 ? uid : nil
    }

    /// The peer's process ID, from LOCAL_PEERPID.
    public var peerPID: pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }

    /// Writes one message. Blocks until the kernel accepts all bytes.
    public func send(_ message: IPCMessage) throws {
        let data = try IPCLine.encode(message)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fileDescriptor, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE { throw IPCError.closed }
                    throw IPCError.errno("write")
                }
                offset += n
            }
        }
    }

    /// Reads once from the socket and returns the messages completed by that read, possibly none. Call it when poll reports the descriptor readable. Throws `IPCError.closed` on EOF.
    public func readAvailable() throws -> [IPCMessage] {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET { throw IPCError.closed }
                throw IPCError.errno("read")
            }
            if n == 0 { throw IPCError.closed }
            return try reader.append(Data(buffer[0..<n]))
        }
    }

    /// Returns the next message, waiting up to `timeout` seconds, or forever when nil. Returns nil on timeout.
    public func receive(timeout: TimeInterval? = nil) throws -> IPCMessage? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while pending.isEmpty {
            var waitMs: Int32 = -1
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return nil }
                waitMs = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            }
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, waitMs)
            if r < 0 {
                if errno == EINTR { continue }
                throw IPCError.errno("poll")
            }
            if r == 0 { return nil }
            pending.append(contentsOf: try readAvailable())
        }
        return pending.removeFirst()
    }
}

/// Fills a sockaddr_un for `path`.
func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw IPCError.socketPathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

public enum IPCClient {
    /// Connects to the host socket. Unless `verifyOwnership` is false, first checks that the socket and its directory belong to this user and that the directory is not accessible by others, so another user can't squat on the path.
    public static func connect(path: String = IPCPaths.hostSocket, timeout: TimeInterval = 0.3, verifyOwnership: Bool = true) throws -> IPCConnection {
        if verifyOwnership {
            try checkOwnership(socketPath: path)
        }
        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.errno("socket") }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else {
                let error = IPCError.errno("connect")
                Darwin.close(fd)
                throw error
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            guard ready > 0 else {
                Darwin.close(fd)
                throw IPCError.timedOut
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 {
                Darwin.close(fd)
                throw IPCError.system("connect", soError)
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return IPCConnection(fileDescriptor: fd)
    }

    static func checkOwnership(socketPath: String) throws {
        let uid = getuid()
        var info = stat()
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard stat(directory, &info) == 0 else { throw IPCError.errno("stat") }
        guard info.st_uid == uid, info.st_mode & 0o077 == 0 else {
            throw IPCError.insecurePath(directory)
        }
        guard lstat(socketPath, &info) == 0 else { throw IPCError.errno("lstat") }
        guard info.st_uid == uid, info.st_mode & S_IFMT == S_IFSOCK else {
            throw IPCError.insecurePath(socketPath)
        }
    }
}

/// A listening Unix socket for the host. Accepts only peers with the same user ID. Call `accept` from one thread at a time.
public final class IPCServer: @unchecked Sendable {
    public let path: String
    public let fileDescriptor: Int32
    private var isClosed = false

    /// Creates the socket's directory with mode 0700 if missing, removes a stale socket file, and listens. Throws `IPCError.addressInUse` if another server answers on the path.
    public init(path: String = IPCPaths.hostSocket) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0 else { throw IPCError.errno("chmod") }

        if access(path, F_OK) == 0 {
            if let live = try? IPCClient.connect(path: path, timeout: 0.2, verifyOwnership: false) {
                live.close()
                throw IPCError.addressInUse
            }
            unlink(path)
        }

        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.errno("socket") }
        let oldMask = umask(0o077)
        let bound = withSockaddr(&address) { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = IPCError.errno("bind")
            Darwin.close(fd)
            throw error
        }
        fileDescriptor = fd
    }

    deinit {
        close()
    }

    /// Stops listening and removes the socket file.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
        unlink(path)
    }

    /// Blocks until a peer with this process's user ID connects. Connections from other users are closed and skipped.
    public func accept() throws -> IPCConnection {
        while true {
            let fd = Darwin.accept(fileDescriptor, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw IPCError.errno("accept")
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(fd)
                continue
            }
            return IPCConnection(fileDescriptor: fd)
        }
    }
}

/// Sends one message to the host and closes the connection. For fire-and-forget events: returns false instead of throwing when the host is down.
@discardableResult
public func sendToHost(_ message: IPCMessage, path: String = IPCPaths.hostSocket, timeout: TimeInterval = 0.3) -> Bool {
    guard let connection = try? IPCClient.connect(path: path, timeout: timeout) else { return false }
    defer { connection.close() }
    return (try? connection.send(message)) != nil
}
