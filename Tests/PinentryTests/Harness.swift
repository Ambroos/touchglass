import Darwin
import Foundation
import Testing
import TouchGlassIPC

/// A temporary directory with a short path, because a Unix socket path holds at most 103 bytes.
final class Sandbox {
    let directory: String

    init() {
        directory = "/tmp/tgp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        mkdir(directory, 0o700)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directory)
    }

    var socketPath: String { directory + "/sock/host.sock" }
    var stubLog: String { directory + "/stub.log" }
    var pinentryLog: String { directory + "/pinentry.log" }
    var stderrPath: String { directory + "/stderr.log" }

    /// Writes the fake pinentry-mac. It greets, appends its arguments and every line it receives to the stub log, answers GETPIN with "stub-secret", and execs a long sleep on CONFIRM so signal forwarding can be tested.
    func writeStub() -> String {
        let path = directory + "/pinentry-stub"
        let script = """
        #!/bin/sh
        echo "ARGS $*" >> "$STUB_LOG"
        echo "OK stub ready"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$STUB_LOG"
          case "$line" in
            GETPIN*) echo "D stub-secret"; echo "OK";;
            "GETINFO flavor") echo "D stub"; echo "OK";;
            CONFIRM*) exec sleep 30;;
            BYE*) echo "OK closing connection"; exit 0;;
            *) echo "OK";;
          esac
        done
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
        return path
    }

    func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Lines the stub received, without its ARGS line.
    var stubLines: [String] {
        read(stubLog).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("ARGS ") }
    }
}

/// How the fake host answers a message. Return nil to stay silent, or `.close` to drop the connection.
enum HostAction {
    case send(IPCMessage)
    case silent
    case close
}

/// A host that accepts connections on the sandbox socket and answers with a scripted closure.
final class FakeHost: @unchecked Sendable {
    let server: IPCServer
    private let lock = NSLock()
    private var messages: [IPCMessage] = []
    private var stopped = false
    private let respond: @Sendable (IPCMessage) -> HostAction

    init(path: String, respond: @escaping @Sendable (IPCMessage) -> HostAction) throws {
        server = try IPCServer(path: path)
        self.respond = respond
        Thread.detachNewThread { [self] in serve() }
    }

    /// Answers pings and the request with fixed replies.
    convenience init(path: String, answer: @escaping @Sendable (IPCMessage) -> IPCMessage?) throws {
        try self.init(path: path) { message in
            if case .ping(let p) = message { return .send(.pong(p)) }
            return answer(message).map(HostAction.send) ?? .silent
        }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.withLock { stopped = true }
        server.close()
    }

    var received: [IPCMessage] {
        lock.withLock { messages }
    }

    /// Waits until a received message matches.
    func waitFor(timeout: Double = 5, _ match: (IPCMessage) -> Bool) -> IPCMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = received.first(where: match) { return found }
            usleep(10_000)
        }
        return nil
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func serve() {
        while !isStopped {
            var pfd = pollfd(fd: server.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0, !isStopped, let connection = try? server.accept() else { continue }
            Thread.detachNewThread { [self] in handle(connection) }
        }
    }

    private func handle(_ connection: IPCConnection) {
        defer { connection.close() }
        while !isStopped {
            let message: IPCMessage
            do {
                guard let next = try connection.receive(timeout: 0.1) else { continue }
                message = next
            } catch {
                return
            }
            lock.withLock { messages.append(message) }
            switch respond(message) {
            case .send(let reply): try? connection.send(reply)
            case .silent: break
            case .close: return
            }
        }
    }
}

/// Runs the touchglass-pinentry binary with scripted stdin and reads its stdout line by line.
final class PinentryDriver {
    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer: [UInt8] = []

    /// The built binary sits next to the test bundle: <products>/PinentryTests.xctest/Contents/MacOS/PinentryTests.
    static let binary: String = {
        var info = Dl_info()
        dladdr(#dsohandle, &info)
        var url = URL(fileURLWithPath: String(cString: info.dli_fname))
        while url.pathExtension != "xctest", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appendingPathComponent("touchglass-pinentry").path
    }()

    init(sandbox: Sandbox, environment: [String: String] = [:], arguments: [String] = []) throws {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": sandbox.directory,
            "TOUCHGLASS_CONFIG": sandbox.directory + "/no-such.conf",
            "TOUCHGLASS_SOCKET": sandbox.socketPath,
            "TOUCHGLASS_HOST_APP": "none",
            "TOUCHGLASS_FALLBACK_PINENTRY": sandbox.writeStub(),
            "TOUCHGLASS_PINENTRY_LOG": sandbox.pinentryLog,
            "STUB_LOG": sandbox.stubLog,
        ]
        env.merge(environment) { $1 }
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.arguments = arguments
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        FileManager.default.createFile(atPath: sandbox.stderrPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: sandbox.stderrPath)
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    var pid: pid_t { process.processIdentifier }

    func send(_ line: String) {
        sendBytes(Array(line.utf8))
    }

    func sendBytes(_ bytes: [UInt8]) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(bytes + [0x0A]))
    }

    func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Reads one line as raw bytes, or nil on timeout or EOF.
    func readLineBytes(timeout: Double = 5) -> [UInt8]? {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000) + 1) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func readLine(timeout: Double = 5) -> String? {
        readLineBytes(timeout: timeout).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Sends a command and returns the response lines up to and including OK or ERR.
    func transact(_ command: String, timeout: Double = 5) -> [String] {
        send(command)
        return readResponse(timeout: timeout)
    }

    func readResponse(timeout: Double = 5) -> [String] {
        var lines: [String] = []
        while let line = readLine(timeout: timeout) {
            lines.append(line)
            if line.hasPrefix("OK") || line.hasPrefix("ERR") { break }
        }
        return lines
    }

    /// Waits for the process to exit. Returns its termination status, or nil if it is still running.
    func waitForExit(timeout: Double = 5) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// The setup gpg-agent sends before a card PIN prompt, as in call-pinentry.c. Returns the greeting.
    func handshake() -> String? {
        let greeting = readLine()
        for command in ["OPTION no-grab", "OPTION ttyname=/dev/ttys009", "OPTION ttytype=xterm-256color", "OPTION lc-ctype=en_US.UTF-8", "OPTION allow-external-password-cache", "OPTION default-ok=_OK", "OPTION default-cancel=_Cancel", "OPTION default-prompt=PIN:", "OPTION touch-file=/tmp/S.gpg-agent", "OPTION owner=4242/501 testhost"] {
            #expect(transact(command) == ["OK"])
        }
        return greeting
    }
}

/// A card PIN description with raw RS and US bytes, as gpg-agent sends it after tabbing is advertised. Fake serial and counter.
let cardSetDesc: [UInt8] = Array("SETDESC Please unlock the card%0A%0A".utf8) + [0x1E] + Array("Number".utf8) + [0x1F] + Array(": 12 345 678%0AHolder".utf8) + [0x1F] + Array(": Test Holder%0ACounter".utf8) + [0x1F] + Array(": 42".utf8)
