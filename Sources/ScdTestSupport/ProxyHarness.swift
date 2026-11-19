import Darwin
import Foundation
import TouchGlassIPC

/// Runs touchglass-scdaemon over fake-scdaemon the way gpg-agent runs it, in a private temporary directory.
public final class ProxyHarness: @unchecked Sendable {
    /// Keygrips of the fake card. Obviously fake values.
    public static let signGrip = String(repeating: "A", count: 40)
    public static let decryptGrip = String(repeating: "B", count: 40)
    public static let authGrip = String(repeating: "C", count: 40)
    public static let serial = "D2760001240100000006123456780000"

    public let directory: String
    public let recordDirectory: String
    public let realSocketPath: String
    public let hostSocketPath: String
    public let runtimeDirectory: String
    public let process: Process
    public let agent: AgentDriver
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// The fake card configuration, as written to fake-scdaemon's JSON config.
    public struct Card: Encodable, Sendable {
        public var pin = "123456"
        public var verified: [Int] = []
        public var pincache = false
        public var pincache_hit = "CAFEF00D"
        public var touch_ms = 0
        public var touch_cache_ms = 0
        public var cached_ms = 0
        public var touch_timeout = false
        public var exit_on_eof: Int32 = 0
        public var eof_linger_ms = 0
        public var split_writes = false
        public init() {}
    }

    private struct FakeConfig: Encodable {
        var socket: String?
        var record_dir: String
        var serial: String
        var keys: [String: Int]
        var card: Card

        func encode(to encoder: Encoder) throws {
            try card.encode(to: encoder)
            var c = encoder.container(keyedBy: Key.self)
            try c.encodeIfPresent(socket, forKey: .socket)
            try c.encode(record_dir, forKey: .record_dir)
            try c.encode(serial, forKey: .serial)
            try c.encode(keys, forKey: .keys)
        }

        enum Key: String, CodingKey { case socket, record_dir, serial, keys }
    }

    /// The directory that holds the built executables.
    public static var productsDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["TOUCHGLASS_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        // The test bundle, or the executable, that this code is linked into sits next to the other products.
        let bundle = Bundle(for: ProxyHarness.self)
        if bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        return bundle.bundleURL
    }

    public static func executable(_ name: String) -> String {
        productsDirectory.appendingPathComponent(name).path
    }

    /// Creates the directory layout and writes the fake card config. Call `start()` to launch the proxy.
    ///
    /// - Parameters:
    ///   - withSocket: Whether fake-scdaemon runs in multi-server mode with a socket.
    ///   - touchDelayMs: The proxy's touch-wait detection delay.
    ///   - hostPath: Host socket path; defaults to `<dir>/host/host.sock`.
    ///   - extraEnvironment: Added to the proxy's environment, to check that it reaches scdaemon.
    ///   - ignoredSignals: Signal names, such as `PIPE`, that the proxy starts with ignored, as it inherits
    ///     them from gpg-agent. A shell sets them and then runs the proxy in its place.
    public init(card: Card = Card(), withSocket: Bool = true, touchDelayMs: Int = 250, hostPath: String? = nil, extraEnvironment: [String: String] = [:], ignoredSignals: [String] = []) throws {
        let base = NSTemporaryDirectory() + "tg-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        directory = base
        recordDirectory = base + "/rec"
        realSocketPath = base + "/S.scdaemon"
        runtimeDirectory = base + "/run"
        hostSocketPath = hostPath ?? base + "/host/host.sock"
        for dir in [base, recordDirectory] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let config = FakeConfig(
            socket: withSocket ? realSocketPath : nil,
            record_dir: recordDirectory,
            serial: Self.serial,
            keys: [Self.signGrip: 1, Self.decryptGrip: 2, Self.authGrip: 3],
            card: card
        )
        let configPath = base + "/fake-scd.json"
        try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: configPath))

        process = Process()
        let proxy = Self.executable("touchglass-scdaemon")
        if ignoredSignals.isEmpty {
            process.executableURL = URL(fileURLWithPath: proxy)
            process.arguments = ["--multi-server"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap '' \(ignoredSignals.joined(separator: " ")) && exec \"$0\" \"$@\"", proxy, "--multi-server"]
        }
        var env = ProcessInfo.processInfo.environment
        env["TOUCHGLASS_SCDAEMON_PROGRAM"] = Self.executable("fake-scdaemon")
        env["TOUCHGLASS_SOCKET"] = hostSocketPath
        env["TOUCHGLASS_RUNTIME_DIR"] = runtimeDirectory
        env["TOUCHGLASS_TOUCH_DELAY_MS"] = String(touchDelayMs)
        env["FAKE_SCD_CONFIG"] = configPath
        env["_assuan_pipe_connect_pid"] = String(getpid())
        // Tests run the proxy outside an app bundle, where it would open any installed TouchGlass by name.
        env["TOUCHGLASS_HOST_APP"] = "none"
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        agent = AgentDriver(input: stdoutPipe.fileHandleForReading, output: stdinPipe.fileHandleForWriting)
    }

    /// Launches the proxy and reads scdaemon's greeting.
    @discardableResult
    public func start() throws -> String? {
        try process.run()
        return agent.readHello()
    }

    /// Runs gpg-agent's start-up handshake and returns the socket path the agent would store.
    public func handshake() -> String? {
        let reply = agent.transact("GETINFO socket_name")
        _ = agent.transact("OPTION event-signal=31")
        let payload = reply.dataPayload
        return payload.isEmpty ? nil : String(decoding: payload, as: UTF8.self)
    }

    /// Opens a socket session the way the agent does for an overlapping session.
    public func openSocketSession(path: String) -> AgentDriver? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let driver = AgentDriver(socket: fd)
        return driver.readHello() == nil ? nil : driver
    }

    /// Raw bytes recorded by fake-scdaemon for a connection ("pipe", "sock1", …) and direction ("in", "out").
    public func recorded(_ connection: String, _ direction: String) -> [UInt8] {
        (try? [UInt8](Data(contentsOf: URL(fileURLWithPath: "\(recordDirectory)/scd-\(connection).\(direction)")))) ?? []
    }

    /// The argument and environment record that fake-scdaemon wrote at start.
    public var scdaemonStartRecord: String {
        (try? String(contentsOfFile: recordDirectory + "/scd-start.txt", encoding: .utf8)) ?? ""
    }

    /// Closes the agent's side of the pipe and waits for the proxy to exit. Returns the termination status
    /// and reason.
    public func finish(timeout: TimeInterval = 5) -> (status: Int32, reason: Process.TerminationReason)? {
        agent.closeOutput()
        return waitForExit(timeout: timeout)
    }

    public func waitForExit(timeout: TimeInterval = 5) -> (status: Int32, reason: Process.TerminationReason)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { return nil }
        return (process.terminationStatus, process.terminationReason)
    }

    /// Stops the proxy if it is still running and removes the temporary directory.
    public func cleanUp() {
        if process.isRunning {
            process.terminate()
            _ = waitForExit(timeout: 2)
        }
        try? FileManager.default.removeItem(atPath: directory)
    }
}
