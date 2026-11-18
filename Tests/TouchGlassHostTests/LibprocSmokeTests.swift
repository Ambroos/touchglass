import Darwin
import Foundation
import Testing
@testable import TouchGlassHost

/// Runs the libproc code against this test process and a child it starts. No gpg is involved: the test
/// process plays the agent, with a listener whose name starts like an agent socket.
@Suite(.serialized) struct LibprocSmokeTests {
    let source = LibprocProcessSource()

    @Test func readsItsOwnRecordArgumentsAndDirectory() throws {
        let record = try #require(source.record(getpid()))
        #expect(record.uid == getuid())
        #expect(record.ppid == getppid())
        #expect(record.startTime > 0)
        let arguments = try #require(source.arguments(getpid()))
        #expect(arguments.argv.count == CommandLine.arguments.count)
        #expect(arguments.argv.first == CommandLine.arguments.first)
        #expect(source.currentDirectory(getpid()) == FileManager.default.currentDirectoryPath)
        #expect(source.processes(uid: getuid()).contains(getpid()))
        #expect(source.record(-5) == nil)
    }

    @Test func socketpairEndsPointAtEachOther() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { close($0) } }
        let sockets = source.unixSockets(getpid())
        let ends = sockets.filter { end in
            end.peerPCB != 0 && sockets.contains { $0.pcb == end.peerPCB && $0.peerPCB == end.pcb }
        }
        #expect(ends.count >= 2)
    }

    @Test func resolverFindsAChildConnectedToAListener() throws {
        let directory = "/tmp/tgc-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/S.gpg-agent"

        let listener = try Self.listen(path)
        defer { close(listener) }
        let client = try Self.connect(path)
        let accepted = accept(listener, nil, nil)
        #expect(accepted >= 0)
        defer { close(accepted) }

        // The accepted socket carries the listener's path; the client's side names it as its peer.
        let ours = source.unixSockets(getpid())
        let serverSide = try #require(ours.first { $0.path == path && $0.peerPCB != 0 })
        let clientSide = try #require(ours.first { $0.pcb == serverSide.peerPCB })
        #expect(clientSide.peerPCB == serverSide.pcb)
        #expect(clientSide.peerPath == path)

        // A child inherits the client socket; the test process then lets go of it.
        let child = try Self.spawnSleep(keeping: client)
        close(client)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }

        // The resolver sees this process as the agent and the child as its client.
        let resolver = ClientResolver(processes: AgentRenamed(base: source, agent: getpid()), files: LocalFileSource(), uid: getuid(), budget: .seconds(2))
        let clients = try #require(resolver.agentClients(deadline: .now + .seconds(2)))
        #expect(clients.map(\.pid) == [child])
        #expect(clients.first?.ssh == false)
        #expect(resolver.label(for: .agentClient(ssh: false)) == "sleep")
        #expect(resolver.label(for: .owner(child)) == "sleep")
    }

    /// The live process table, with one PID reported under the agent's name and any real agent renamed,
    /// so the test never looks at a real agent's clients.
    struct AgentRenamed: ProcessSource {
        let base: LibprocProcessSource
        let agent: Int32

        func processes(uid: UInt32) -> [Int32] { base.processes(uid: uid) }
        func record(_ pid: Int32) -> ProcessRecord? {
            guard var record = base.record(pid) else { return nil }
            if pid == agent {
                record.name = "gpg-agent"
            } else if record.name == "gpg-agent" {
                record.name = "other-agent"
            }
            return record
        }
        func arguments(_ pid: Int32) -> ProcessArguments? { base.arguments(pid) }
        func currentDirectory(_ pid: Int32) -> String? { base.currentDirectory(pid) }
        func unixSockets(_ pid: Int32) -> [UnixSocketRecord] { base.unixSockets(pid) }
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
        }
        return address
    }

    static func listen(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        return fd
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    /// Starts `/bin/sleep` with `fd` open in it and every other descriptor closed.
    static func spawnSleep(keeping fd: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fd, 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, "/bin/sleep", &actions, &attributes, argv, environ) == 0 else { throw POSIXError(.ECHILD) }
        // Wait until the child has exec'd, so its arguments read as sleep's.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, LibprocProcessSource().arguments(pid)?.argv.first != "sleep" {
            usleep(10_000)
        }
        return pid
    }
}
