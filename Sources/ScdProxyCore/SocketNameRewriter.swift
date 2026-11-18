import Synchronization

/// Replaces the path in scdaemon's reply to `GETINFO socket_name` with the proxy's own socket.
///
/// gpg-agent asks for the socket name once and connects to it for every session that overlaps the one on
/// the pipe. Pointing it at the proxy's socket lets the proxy relay and observe those sessions too. This is
/// the only change the proxy makes to the byte stream.
///
/// The client-to-server thread calls `arm()` before it forwards the command line, so the reply cannot arrive
/// before the rewriter expects it. The server-to-client thread passes every chunk through `process(_:)`.
/// While no reply is expected, `process(_:)` returns the chunk untouched without copying it.
public final class SocketNameRewriter: Sendable {
    /// The `D` line payload that replaces scdaemon's, already percent-escaped.
    private let replacement: [UInt8]
    private let onRealPath: @Sendable (String) -> Void
    private let pending = Atomic<Int>(0)
    private let state = Mutex(LineState())

    private struct LineState: Sendable {
        var line: [UInt8] = []
        var atLineStart = true
        /// The current line started before the rewriter armed, so it is passed through as is.
        var inTail = false
    }

    /// The longest reply line the rewriter buffers. Longer lines turn the rewrite off for that reply.
    static let maxBufferedLine = 4096

    /// - Parameters:
    ///   - proxySocketPath: The path that the client sees. Must not contain `%`, CR or LF.
    ///   - onRealPath: Receives scdaemon's own socket path, unescaped, each time the reply passes.
    public init(proxySocketPath: String, onRealPath: @escaping @Sendable (String) -> Void) {
        replacement = Array(proxySocketPath.utf8)
        self.onRealPath = onRealPath
    }

    /// True if `line` is a `GETINFO socket_name` command.
    public static func isSocketNameQuery(_ line: WireLine) -> Bool {
        guard case let .command(keyword, args) = line, keyword == "GETINFO" else { return false }
        return args.first?.lowercased() == "socket_name"
    }

    /// Marks that the next reply on this connection answers `GETINFO socket_name`.
    public func arm() {
        pending.add(1, ordering: .sequentiallyConsistent)
    }

    /// Returns the bytes to forward for `chunk`: the chunk itself, or a rewritten copy.
    public func process(_ chunk: UnsafeRawBufferPointer) -> [UInt8]? {
        state.withLock { state in
            if pending.load(ordering: .sequentiallyConsistent) == 0 && state.line.isEmpty {
                if let last = chunk.last { state.atLineStart = last == 0x0A }
                return nil
            }
            if state.line.isEmpty && !state.atLineStart { state.inTail = true }

            var out: [UInt8] = []
            out.reserveCapacity(chunk.count + replacement.count)
            var i = 0
            while i < chunk.count {
                if pending.load(ordering: .sequentiallyConsistent) == 0 && state.line.isEmpty {
                    out.append(contentsOf: chunk[i...])
                    state.atLineStart = chunk.last == 0x0A
                    return out
                }
                let byte = chunk[i]
                i += 1
                state.line.append(byte)
                if byte == 0x0A {
                    out.append(contentsOf: finishLine(&state))
                    state.line.removeAll(keepingCapacity: true)
                    state.atLineStart = true
                } else if state.line.count > Self.maxBufferedLine {
                    // Not an Assuan reply we understand: give up on this reply and pass everything through.
                    out.append(contentsOf: state.line)
                    state.line.removeAll()
                    state.inTail = false
                    state.atLineStart = false
                    pending.store(0, ordering: .sequentiallyConsistent)
                }
            }
            return out
        }
    }

    /// Returns the bytes to forward for one complete line, including its LF.
    private func finishLine(_ state: inout LineState) -> [UInt8] {
        let line = state.line
        if state.inTail {
            state.inTail = false
            return line
        }
        var content = line.dropLast()
        if content.last == 0x0D { content = content.dropLast() }
        if content.starts(with: [UInt8(ascii: "D"), 0x20]) {
            onRealPath(Self.percentDecode(content.dropFirst(2)))
            return [UInt8(ascii: "D"), 0x20] + replacement + [0x0A]
        }
        if content.starts(with: Array("OK".utf8)) || content.starts(with: Array("ERR".utf8)) {
            pending.subtract(1, ordering: .sequentiallyConsistent)
        }
        return line
    }

    static func percentDecode(_ bytes: ArraySlice<UInt8>) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.endIndex,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
