import Darwin

/// Buffered reader of LF-terminated lines from a file descriptor.
final class LineInput {
    let fd: Int32
    private(set) var buffer: [UInt8] = []
    private(set) var reachedEOF = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Removes and returns the next complete line without its LF and an optional trailing CR.
    func nextLine() -> [UInt8]? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var line = Array(buffer[..<newline])
        buffer.removeSubrange(...newline)
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    /// Removes and returns everything buffered.
    func takeBuffer() -> [UInt8] {
        defer { buffer.removeAll() }
        return buffer
    }

    /// Reads once. Returns false on EOF or a read error.
    @discardableResult
    func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                reachedEOF = true
                return false
            }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }
    }
}

/// Writes all bytes to a descriptor. Returns false if the descriptor is closed or fails.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += n
    }
    return true
}

/// Monotonic time in seconds.
func now() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// Polls descriptors for input. Returns the set of descriptors that are readable or hung up, empty on timeout.
func waitReadable(_ fds: [Int32], timeout: Double?) -> Set<Int32> {
    var pfds = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    let ms: Int32 = timeout.map { Int32(max(0, min($0 * 1000, 600_000)).rounded(.up)) } ?? -1
    let r = poll(&pfds, nfds_t(pfds.count), ms)
    guard r > 0 else { return [] }
    return Set(pfds.filter { $0.revents != 0 }.map(\.fd))
}

// MARK: Signals

/// Write end of the self-pipe that the signal handler writes the signal number to.
nonisolated(unsafe) private var signalPipeWrite: Int32 = -1

/// Routes SIGINT, SIGTERM and SIGHUP to a pipe and ignores SIGPIPE. Returns the pipe's read end.
func installSignalPipe() -> Int32 {
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    for fd in fds {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    signalPipeWrite = fds[1]
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig) { number in
            var byte = UInt8(truncatingIfNeeded: number)
            _ = write(signalPipeWrite, &byte, 1)
        }
    }
    signal(SIGPIPE, SIG_IGN)
    return fds[0]
}

/// Drains the signal pipe and returns the signals received.
func drainSignals(_ fd: Int32) -> [Int32] {
    var bytes = [UInt8](repeating: 0, count: 16)
    let n = read(fd, &bytes, bytes.count)
    return n > 0 ? bytes[0..<n].map { Int32($0) } : []
}

// MARK: Processes

/// Starts `path` with `arguments` (excluding argv[0]). Each of stdin, stdout and stderr is either the given descriptor or /dev/null when nil. All other descriptors are closed in the child and signal dispositions are reset to default.
func spawn(_ path: String, _ arguments: [String], stdin: Int32?, stdout: Int32?, stderr: Int32?) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (source, target) in [(stdin, Int32(0)), (stdout, 1), (stderr, 2)] {
        if let source {
            posix_spawn_file_actions_adddup2(&actions, source, target)
        } else {
            posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
        }
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
        sigaddset(&defaults, sig)
    }
    var empty = sigset_t()
    sigemptyset(&empty)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &empty)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
    return result == 0 ? pid : nil
}

/// Waits for a child and converts its status to an exit code: the exit status, or 128 plus the signal number.
func waitExitCode(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { return 1 }
    }
    let signal = status & 0x7F
    return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
}
