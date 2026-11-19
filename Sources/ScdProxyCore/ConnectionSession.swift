import Darwin
import Foundation

/// Forwards one Assuan connection in both directions and feeds a copy of the traffic to the detector.
///
/// Each direction runs on its own thread with blocking `read` and `write`. The only work on the forwarding
/// path is the line tap (a byte scan with a small bounded buffer) and, for the reply to `GETINFO socket_name`,
/// the rewriter. Neither waits on the detector or the host.
///
/// Both directions hand their lines to the detector before forwarding the bytes. The peer can answer only
/// after the write, so the detector sees an `INQUIRE NEEDPIN` before the agent's `END` and a `PKSIGN` before
/// scdaemon's reply, even when the other direction's thread runs first.
public final class ConnectionSession: @unchecked Sendable {
    public let id: String
    private let detector: OperationDetector
    private let rewriter: SocketNameRewriter?
    private var clientTap = AssuanTap(direction: .toServer)
    private var serverTap = AssuanTap(direction: .toClient)

    static let bufferSize = 64 * 1024

    public init(id: String, detector: OperationDetector, rewriter: SocketNameRewriter?) {
        self.id = id
        self.detector = detector
        self.rewriter = rewriter
    }

    /// Forwards client bytes from `source` to `destination` until end of file or an error.
    /// Returns true on end of file, false if either side failed.
    public func pumpClientToServer(from source: Int32, to destination: Int32) -> Bool {
        pump(from: source) { chunk in
            let lines = clientTap.feed(chunk)
            if let rewriter, lines.contains(where: SocketNameRewriter.isSocketNameQuery) {
                rewriter.arm()
            }
            detector.observe(connection: id, direction: .toServer, lines: lines, time: Date().timeIntervalSince1970)
            return Posix.writeAll(destination, chunk)
        }
    }

    /// Forwards server bytes from `source` to `destination` until end of file or an error.
    /// Returns true on end of file, false if either side failed.
    public func pumpServerToClient(from source: Int32, to destination: Int32) -> Bool {
        pump(from: source) { chunk in
            let lines = serverTap.feed(chunk)
            detector.observe(connection: id, direction: .toClient, lines: lines, time: Date().timeIntervalSince1970)
            if let rewritten = rewriter?.process(chunk) {
                return Posix.writeAll(destination, rewritten)
            }
            return Posix.writeAll(destination, chunk)
        }
    }

    private func pump(from source: Int32, forward: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 1)
        defer {
            // Scrub the buffer: it held PIN and inquiry bytes.
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.deallocate()
        }
        while true {
            let n = Posix.read(source, buffer)
            if n == 0 { return true }
            if n < 0 { return false }
            if !forward(UnsafeRawBufferPointer(rebasing: buffer[0..<n])) { return false }
        }
    }
}
