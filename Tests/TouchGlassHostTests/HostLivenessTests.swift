import Darwin
import Foundation
import Testing
import TouchGlassIPC
@testable import TouchGlassHost

/// The pinentry's heartbeat must stop when the host's main thread stops, since the main thread shows the panel.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HostLivenessTests {
    /// Blocks the main thread for the given time, returning once the block has started.
    static func blockMainThread(microseconds: useconds_t) {
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            started.signal()
            usleep(microseconds)
        }
        started.wait()
    }

    @Test func pongsWaitForTheMainThreadAndStaleOnesAreDropped() throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = try HostServer(path: socket)
        server.start(onMessage: { _, _ in }, onClose: { _ in })
        defer { server.stop() }

        let client = try IPCClient.connect(path: socket, timeout: 1)
        defer { client.close() }
        try client.send(.hello(Hello(role: .pinentry)))
        try client.send(.ping(Ping(seq: 1)))
        #expect(try client.receive(timeout: 2) == .pong(Ping(seq: 1)))

        Self.blockMainThread(microseconds: 1_600_000)
        try client.send(.ping(Ping(seq: 2)))
        // No pong while the main thread is blocked, and none after: it would be older than the deadline.
        #expect(try client.receive(timeout: 2.2) == nil)

        try client.send(.ping(Ping(seq: 3)))
        #expect(try client.receive(timeout: 2) == .pong(Ping(seq: 3)))
    }

    /// The host answers nothing while its main thread is blocked, so the pinentry gives up after
    /// `host-stall-ms` and hands the request to its fallback (here /usr/bin/false, which fails the replay).
    /// Before the fix, pongs kept coming and the pinentry waited for the panel's answer instead.
    @Test func pinentryFallsBackWhenTheHostMainThreadStalls() async throws {
        let (directory, socket) = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = try HostServer(path: socket)
        let panel = await RecordingPanel()
        await MainActor.run { panel.autoSubmit = "123456" }
        let session = await HostSession(server: server, panel: panel)
        await session.start()

        let pinentry = try PinentryProcess(socket: socket, home: directory, environment: [
            "TOUCHGLASS_PING_INTERVAL_MS": "150",
            "TOUCHGLASS_HOST_STALL_MS": "700",
        ])
        defer { pinentry.stop() }
        #expect(await pinentry.readLine()?.hasPrefix("OK") == true)

        Self.blockMainThread(microseconds: 2_500_000)
        pinentry.send("GETPIN")
        let answer = await pinentry.readLine()
        #expect(answer?.hasPrefix("ERR") == true, "got \(answer ?? "nothing")")
        await session.stop()
    }
}
