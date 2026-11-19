import Foundation
import Testing
import TouchGlassIPC
@testable import ScdProxyCore

@Suite struct AssuanTapTests {
    @Test func classifiesServerLines() {
        var tap = AssuanTap(direction: .toClient)
        let input = "OK hello\nS KEYINFO AAAA T D276 OPENPGP.1 sc\nS PINCACHE_PUT 0/openpgp/1 0011\nINQUIRE NEEDPIN ||Please unlock\nERR 100663383 Bad PIN <SCD>\n# comment\nD abc\n"
        let lines = tap.feed(Array(input.utf8))
        #expect(lines == [
            .ok,
            .status(keyword: "KEYINFO", args: ["AAAA", "T", "D276", "OPENPGP.1", "sc"]),
            .status(keyword: "PINCACHE_PUT", args: []),
            .inquire(keyword: "NEEDPIN", args: []),
            .err(code: 100663383),
            .comment,
            .data,
        ])
    }

    @Test func classifiesClientLinesAndKeepsOnlyNeededArguments() {
        var tap = AssuanTap(direction: .toServer)
        let lines = tap.feed(Array("SETDATA 3051AB\npksign --hash=sha512 AAAA\r\nEND\nCAN\n\nGETINFO socket_name\n".utf8))
        #expect(lines == [
            .command(keyword: "SETDATA", args: []),
            .command(keyword: "PKSIGN", args: ["--hash=sha512", "AAAA"]),
            .end,
            .cancel,
            .command(keyword: "GETINFO", args: ["socket_name"]),
        ])
    }

    @Test func handlesLinesSplitAtEveryByte() {
        var tap = AssuanTap(direction: .toClient)
        var lines: [WireLine] = []
        for byte in Array("S KEYINFO G T S OPENPGP.3 sa\nD \0\u{1}x\nOK\n".utf8) {
            lines += tap.feed([byte])
        }
        #expect(lines == [.status(keyword: "KEYINFO", args: ["G", "T", "S", "OPENPGP.3", "sa"]), .data, .ok])
    }

    @Test func neverBuffersDataLinePayload() {
        // A PIN answer: D, the PIN, NUL padding, then END. The tap must report a data line and nothing of its content.
        var tap = AssuanTap(direction: .toServer)
        let pin = Array("D 987654".utf8) + [UInt8](repeating: 0, count: 84) + [0x0A]
        let lines = tap.feed(pin + Array("END\n".utf8))
        #expect(lines == [.data, .end])
    }

    @Test func survivesOverlongLines() {
        var tap = AssuanTap(direction: .toClient)
        let long = [UInt8](repeating: UInt8(ascii: "S"), count: 5000) + [0x0A]
        #expect(tap.feed(long + Array("OK\n".utf8)) == [.other, .ok])
    }
}

@Suite struct SocketNameRewriterTests {
    final class PathBox: @unchecked Sendable {
        var value: String?
    }

    func run(_ rewriter: SocketNameRewriter, _ chunks: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for chunk in chunks {
            out += chunk.withUnsafeBytes { rewriter.process($0) } ?? chunk
        }
        return out
    }

    @Test func passesThroughWhenNotArmed() {
        let rewriter = SocketNameRewriter(proxySocketPath: "/p") { _ in }
        let bytes = Array("D /real\nOK\n".utf8)
        #expect(bytes.withUnsafeBytes { rewriter.process($0) } == nil)
    }

    @Test func rewritesReplySplitAcrossChunks() {
        let box = PathBox()
        let rewriter = SocketNameRewriter(proxySocketPath: "/proxy/scd.sock") { box.value = $0 }
        rewriter.arm()
        let reply = Array("D /home/u/.gnupg/S.scd%25aemon\nOK\nS NEXT\n".utf8)
        let out = run(rewriter, reply.map { [$0] })
        #expect(String(decoding: out, as: UTF8.self) == "D /proxy/scd.sock\nOK\nS NEXT\n")
        #expect(box.value == "/home/u/.gnupg/S.scd%aemon")
    }

    @Test func leavesEmptyReplyAlone() {
        let rewriter = SocketNameRewriter(proxySocketPath: "/proxy") { _ in }
        rewriter.arm()
        #expect(run(rewriter, [Array("OK\nD later\n".utf8)]) == Array("OK\nD later\n".utf8))
    }
}

@Suite struct OperationDetectorTests {
    final class Collector: EventSink, @unchecked Sendable {
        let lock = NSLock()
        var messages: [IPCMessage] = []
        func send(_ message: IPCMessage) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }
        var summaries: [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages.map(\.shortSummary)
        }
    }

    func feed(_ detector: OperationDetector, _ dir: StreamDirection, _ text: String) {
        var tap = AssuanTap(direction: dir)
        detector.observe(connection: "c", direction: dir, lines: tap.feed(Array(text.utf8)), time: Date().timeIntervalSince1970)
    }

    @Test func pksignWithAuthGripIsAuthentication() {
        let sink = Collector()
        let detector = OperationDetector(sink: sink, touchDelay: 10)
        feed(detector, .toClient, "S KEYINFO CCCC T SERIAL OPENPGP.3 sa\nOK\n")
        feed(detector, .toServer, "PKSIGN --hash=sha1 cccc\n")
        feed(detector, .toClient, "D sig\nOK\n")
        detector.drain()
        guard case let .opStart(start) = sink.messages.first else {
            Issue.record("no op_start")
            return
        }
        #expect(start.op == .auth && start.slot == 3 && start.serial == "SERIAL")
        #expect(sink.summaries == ["op_start c auth", "op_end c ok"])
    }

    @Test func mapsErrorCodes() {
        #expect(OperationDetector.result(forErrorCode: 100663383) == .badPin)
        #expect(OperationDetector.result(forErrorCode: 100663358) == .timeout)
        #expect(OperationDetector.result(forErrorCode: 100663573) == .cancelled)
        #expect(OperationDetector.result(forErrorCode: 83886179) == .cancelled)
        #expect(OperationDetector.result(forErrorCode: 100663406) == .error)
        #expect(OperationDetector.result(forErrorCode: nil) == .error)
    }

    @Test func pincacheGetIsNotAPinStep() {
        let sink = Collector()
        let detector = OperationDetector(sink: sink, touchDelay: 10)
        feed(detector, .toServer, "PKSIGN X\n")
        feed(detector, .toClient, "INQUIRE PINCACHE_GET 0/openpgp/1\n")
        feed(detector, .toServer, "D 00AA\nEND\n")
        feed(detector, .toClient, "OK\n")
        detector.drain()
        #expect(sink.summaries == ["op_start c sign", "op_end c ok"])
    }

    @Test func ackPromptIsAnExactTouchSignal() {
        let sink = Collector()
        let detector = OperationDetector(sink: sink, touchDelay: 10)
        feed(detector, .toServer, "PKAUTH X\n")
        feed(detector, .toClient, "INQUIRE POPUPPINPADPROMPT --ack\n")
        feed(detector, .toServer, "END\n")
        feed(detector, .toClient, "INQUIRE DISMISSPINPADPROMPT\n")
        feed(detector, .toServer, "END\n")
        feed(detector, .toClient, "OK\n")
        detector.drain()
        #expect(sink.summaries == ["op_start c auth", "touch_wait c", "op_end c ok"])
    }

    @Test func closedConnectionEndsOperation() {
        let sink = Collector()
        let detector = OperationDetector(sink: sink, touchDelay: 10)
        feed(detector, .toServer, "PKDECRYPT X\n")
        detector.closed(connection: "c")
        detector.drain()
        #expect(sink.summaries == ["op_start c decrypt", "op_end c error"])
    }
}

/// The detector must see each line before the peer can answer it. Otherwise, when the forwarding thread
/// stalls after its write, the agent's `END` reaches the detector before scdaemon's `INQUIRE NEEDPIN`, and
/// the host gets neither `pin_sent` nor `touch_wait`.
@Suite struct ConnectionSessionTests {
    /// Runs one pump over `bytes` while its destination pipe is full, so the forwarding write blocks, and
    /// returns the detector's events from that moment, waiting up to 2 s for `count` of them. Then drains the
    /// pipe and lets the pump finish.
    func eventsWhileForwardingBlocks(
        _ bytes: String,
        expecting count: Int,
        prepare: (OperationDetector) -> Void = { _ in },
        pump: @escaping @Sendable (ConnectionSession, Int32, Int32) -> Void
    ) -> [String] {
        let sink = OperationDetectorTests.Collector()
        let detector = OperationDetector(sink: sink, touchDelay: 10)
        prepare(detector)
        let session = ConnectionSession(id: "c", detector: detector, rewriter: nil)
        var source: [Int32] = [0, 0]
        var destination: [Int32] = [0, 0]
        guard pipe(&source) == 0, pipe(&destination) == 0 else { return [] }
        defer { [source[0], destination[0], destination[1]].forEach { close($0) } }

        Posix.setNonBlocking(destination[1], true)
        var filler = [UInt8](repeating: 0x20, count: 4096)
        var queued = 0
        while true {
            let n = write(destination[1], &filler, filler.count)
            if n <= 0 { break }
            queued += n
        }
        Posix.setNonBlocking(destination[1], false)

        Posix.writeAll(source[1], Array(bytes.utf8))
        close(source[1])
        let done = DispatchSemaphore(value: 0)
        let (input, output) = (source[0], destination[1])
        Thread.detachNewThread {
            pump(session, input, output)
            done.signal()
        }

        let deadline = Date(timeIntervalSinceNow: 2)
        var events: [String] = []
        while Date() < deadline {
            detector.drain()
            events = sink.summaries
            if events.count >= count { break }
            usleep(10_000)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var remaining = queued + bytes.utf8.count
        while remaining > 0 {
            let n = read(destination[0], &buffer, buffer.count)
            if n <= 0 { break }
            remaining -= n
        }
        done.wait()
        return events
    }

    @Test func serverLinesReachTheDetectorBeforeTheAgent() {
        let events = eventsWhileForwardingBlocks("INQUIRE NEEDPIN ||Please enter the PIN\n", expecting: 2) { detector in
            var tap = AssuanTap(direction: .toServer)
            detector.observe(connection: "c", direction: .toServer, lines: tap.feed(Array("PKSIGN X\n".utf8)), time: Date().timeIntervalSince1970)
        } pump: { session, input, output in
            _ = session.pumpServerToClient(from: input, to: output)
        }
        #expect(events == ["op_start c sign", "pin_needed c"])
    }

    @Test func clientLinesReachTheDetectorBeforeScdaemon() {
        let events = eventsWhileForwardingBlocks("PKSIGN X\n", expecting: 1) { session, input, output in
            _ = session.pumpClientToServer(from: input, to: output)
        }
        #expect(events == ["op_start c sign"])
    }
}

extension IPCMessage {
    var shortSummary: String {
        switch self {
        case let .opStart(m): "op_start \(m.conn) \(m.op.rawValue)"
        case let .pinNeeded(m): "pin_needed \(m.conn)"
        case let .pinSent(m): "pin_sent \(m.conn)"
        case let .touchWait(m): "touch_wait \(m.conn)"
        case let .opEnd(m): "op_end \(m.conn) \(m.result.rawValue)"
        default: type
        }
    }
}
