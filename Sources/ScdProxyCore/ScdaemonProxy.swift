import Darwin
import Foundation
import Synchronization
import TouchGlassIPC

/// Runs the real scdaemon as a child and relays its pipe and socket traffic.
///
/// Process rules, from how gpg-agent manages scdaemon:
/// - The child gets this process's arguments and environment unchanged. scdaemon reads the agent's PID from
///   `_assuan_pipe_connect_pid` and signals it on card events.
/// - The agent waits on this process's PID, so it exits only after the child exits, with the child's status.
/// - At end of file from the agent, the proxy closes the child's stdin and keeps forwarding its output.
/// - `SIGTERM`, `SIGINT` and `SIGHUP` are forwarded to the child instead of ending the proxy.
/// - `SIGUSR1` and `SIGUSR2` are ignored. scdaemon sends its event signal to the peer of a socket session,
///   which is the proxy for a relayed one; ending the proxy would make the agent think scdaemon exited.
public final class ScdaemonProxy: @unchecked Sendable {
    private let config: ProxyConfig
    private let detector: OperationDetector
    private let sink: HostEventSink
    private let realSocketPath = Mutex<String?>(nil)
    private var proxySocketPath: String?
    private var listener: Int32 = -1
    private let socketCounter = Atomic<Int>(0)
    private let pid = getpid()

    /// The child's PID, for the signal handler.
    nonisolated(unsafe) static var childPID: pid_t = 0

    public init(config: ProxyConfig) {
        self.config = config
        var launch: (@Sendable () -> Bool)?
        if let target = config.hostApp {
            launch = { Self.launchHost(target) }
        }
        sink = HostEventSink(path: config.hostSocketPath, launchHost: launch)
        detector = OperationDetector(sink: sink, touchDelay: config.touchDelay)
    }

    /// Starts the child, forwards traffic until it exits, then exits with its status.
    public func run(arguments: [String]) -> Never {
        guard let pipes = makePipes(), let child = spawn(arguments: arguments, pipes: pipes) else {
            FileHandle.standardError.write(Data("touchglass-scdaemon: cannot start \(config.scdaemonPath)\n".utf8))
            exit(2)
        }
        Self.childPID = child
        installSignalHandlers()
        Posix.close(pipes.childStdin)
        Posix.close(pipes.childStdout)

        startRelayListener()
        let pipeSession = ConnectionSession(id: "\(pid):p", detector: detector, rewriter: makeRewriter())

        let toChild = pipes.toChild
        let fromChild = pipes.fromChild
        Thread.detachNewThread {
            _ = pipeSession.pumpClientToServer(from: STDIN_FILENO, to: toChild)
            // End of file or error from the agent: let scdaemon see end of file on its stdin.
            Posix.close(toChild)
        }
        let outputDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = pipeSession.pumpServerToClient(from: fromChild, to: STDOUT_FILENO)
            // Either scdaemon closed its stdout or the agent stopped reading. Closing our end gives scdaemon
            // the same EPIPE it gets without the proxy.
            Posix.close(fromChild)
            outputDone.signal()
        }

        let status = waitForChild(child)
        // scdaemon closes its stdout when it exits; give the output thread a moment to forward the rest.
        _ = outputDone.wait(timeout: .now() + 2)
        // End every open operation, the socket sessions' too: their relay threads may not finish before exit.
        detector.closeAll()
        sink.flush(timeout: 0.3)
        if let proxySocketPath { unlink(proxySocketPath) }
        exitLike(status)
    }

    // MARK: - Child process

    private struct Pipes {
        var childStdin: Int32
        var toChild: Int32
        var fromChild: Int32
        var childStdout: Int32
    }

    private func makePipes() -> Pipes? {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { return nil }
        guard pipe(&output) == 0 else {
            Posix.close(input[0]); Posix.close(input[1])
            return nil
        }
        Posix.setCloseOnExec(input[1])
        Posix.setCloseOnExec(output[0])
        return Pipes(childStdin: input[0], toChild: input[1], fromChild: output[0], childStdout: output[1])
    }

    private func spawn(arguments: [String], pipes: Pipes) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes.childStdin, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes.childStdout, STDOUT_FILENO)
        // gpg-agent keeps stderr open only when it is not detached; pass it on only if we have it.
        if fcntl(STDERR_FILENO, F_GETFD) >= 0 {
            posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every other descriptor in the child, as gpg-agent does when it starts scdaemon itself.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv0 = (config.scdaemonPath as NSString).lastPathComponent
        let argv = [argv0] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        var child: pid_t = 0
        let result = posix_spawn(&child, config.scdaemonPath, &actions, &attributes, &cArgs, environ)
        return result == 0 ? child : nil
    }

    private func installSignalHandlers() {
        Posix.ignoreSIGPIPE()
        let forward: @convention(c) (Int32) -> Void = { signal in
            if ScdaemonProxy.childPID > 0 { kill(ScdaemonProxy.childPID, signal) }
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = forward
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
    }

    /// Starts the host app and reaps `open` on a background thread. Runs on the sink's thread.
    private static func launchHost(_ target: String) -> Bool {
        guard let opener = HostLauncher.launch(target) else { return false }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(opener, &status, 0) < 0 && errno == EINTR {}
        }
        return true
    }

    private func waitForChild(_ child: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno != EINTR { return 1 << 8 }
        }
        return status
    }

    /// Exits with the same status as the child: its exit code, or death by the same signal.
    private func exitLike(_ status: Int32) -> Never {
        let signalNumber = status & 0x7F
        if signalNumber == 0 { exit((status >> 8) & 0xFF) }
        signal(signalNumber, SIG_DFL)
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, signalNumber)
        sigprocmask(SIG_UNBLOCK, &unblock, nil)
        kill(getpid(), signalNumber)
        exit(128 + signalNumber)
    }

    // MARK: - Socket relay

    private func makeRewriter() -> SocketNameRewriter? {
        guard let proxySocketPath else { return nil }
        return SocketNameRewriter(proxySocketPath: proxySocketPath) { [self] path in
            realSocketPath.withLock { $0 = path }
        }
    }

    /// Listens on `<runtime dir>/scd.<pid>.sock`. On any failure the proxy runs without a relay: the agent
    /// then gets scdaemon's own socket and overlapping sessions work, unobserved.
    private func startRelayListener() {
        guard let dir = config.runtimeDirectory, Posix.ensurePrivateDirectory(dir) else { return }
        removeStaleSockets(in: dir)
        let path = dir + "/scd.\(pid).sock"
        guard !path.contains(where: { $0 == "%" || $0 == "\r" || $0 == "\n" }),
              path.utf8.count <= Posix.maxSocketPathLength,
              let fd = Posix.listenUnix(path: path)
        else { return }
        listener = fd
        proxySocketPath = path
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func removeStaleSockets(in dir: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasPrefix("scd.") && name.hasSuffix(".sock") {
            let middle = name.dropFirst(4).dropLast(5)
            guard let owner = pid_t(middle), owner != pid else { continue }
            if kill(owner, 0) != 0 && errno == ESRCH { unlink(dir + "/" + name) }
        }
    }

    private func acceptLoop() {
        while let client = Posix.accept(listener) {
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                Posix.close(client)
                continue
            }
            let number = socketCounter.add(1, ordering: .relaxed).newValue
            Thread.detachNewThread { [self] in relay(client: client, id: "\(pid):s\(number)") }
        }
    }

    /// Relays one agent connection to scdaemon's socket until both directions reach end of file.
    private func relay(client: Int32, id: String) {
        guard let target = realSocketPath.withLock({ $0 }), let server = Posix.connectUnix(path: target) else {
            Posix.close(client)
            return
        }
        let session = ConnectionSession(id: id, detector: detector, rewriter: makeRewriter())
        let upstreamDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = session.pumpClientToServer(from: client, to: server)
            shutdown(server, SHUT_WR)
            upstreamDone.signal()
        }
        _ = session.pumpServerToClient(from: server, to: client)
        shutdown(client, SHUT_WR)
        // scdaemon closed the connection. Stop the other direction too, then release both descriptors.
        shutdown(client, SHUT_RD)
        upstreamDone.wait()
        Posix.close(client)
        Posix.close(server)
        detector.closed(connection: id)
    }
}
