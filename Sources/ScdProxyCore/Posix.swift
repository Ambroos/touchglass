import Darwin

/// Thin wrappers over POSIX calls used by the proxy and its test tools.
public enum Posix {
    /// Writes all bytes to `fd`, retrying on `EINTR` and partial writes.
    /// Returns false on any other error, such as `EPIPE` after the reader closed.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        guard var base = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let n = Darwin.write(fd, base, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            remaining -= n
            base += n
        }
        return true
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { writeAll(fd, $0) }
    }

    /// Reads up to `buffer.count` bytes, retrying on `EINTR`.
    /// Returns the byte count, 0 at end of file, or -1 on error.
    public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    /// Closes `fd`, ignoring errors. Does nothing for negative descriptors.
    public static func close(_ fd: Int32) {
        if fd >= 0 { _ = Darwin.close(fd) }
    }

    /// Ignores `SIGPIPE` so a closed peer turns into an `EPIPE` error instead of killing the process.
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    public static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    public static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    public static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The largest path that fits in `sockaddr_un.sun_path`, leaving room for the terminating NUL.
    public static let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func withSocketAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxSocketPathLength, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Creates a listening Unix socket at `path`, replacing any stale socket file there.
    /// The socket file gets mode 0600. Returns the descriptor or nil.
    public static func listenUnix(path: String, backlog: Int32 = 16) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        unlink(path)
        let oldMask = umask(0o177)
        let bound = withSocketAddress(path) { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0, Darwin.listen(fd, backlog) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Connects to the Unix socket at `path`. With `nonBlocking`, the descriptor stays non-blocking and
    /// the call fails instead of waiting when the listener's backlog is full.
    public static func connectUnix(path: String, nonBlocking: Bool = false) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        setNoSigPipe(fd)
        if nonBlocking { setNonBlocking(fd, true) }
        let result = withSocketAddress(path) { addr, len -> Int32 in
            while true {
                let r = connect(fd, addr, len)
                if r < 0 && errno == EINTR { continue }
                return r
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Accepts a connection, retrying on `EINTR`. Returns nil when the listener is closed or fails.
    public static func accept(_ listener: Int32) -> Int32? {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 {
                setCloseOnExec(fd)
                setNoSigPipe(fd)
                return fd
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// Creates `path` as a directory with mode 0700 if it does not exist, then checks that it is a directory
    /// owned by the current user with no group or other permissions.
    public static func ensurePrivateDirectory(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return false }
        return isPrivateDirectory(path)
    }

    /// True if `path` is a directory, not a symbolic link, owned by the current user, with mode 0700 or stricter.
    public static func isPrivateDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() && (st.st_mode & 0o077) == 0
    }

    public static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
