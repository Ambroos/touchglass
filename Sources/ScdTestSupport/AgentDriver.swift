import Darwin
import Foundation
import ScdProxyCore

/// The client side of an Assuan connection, acting as gpg-agent towards scdaemon or the proxy.
///
/// Records every byte it sends and receives, so tests can compare them with what the fake scdaemon saw.
public final class AgentDriver: @unchecked Sendable {
    public let input: Int32
    public let output: Int32
    /// Bytes sent, in order.
    public private(set) var sent: [UInt8] = []
    /// Bytes received, in order.
    public private(set) var received: [UInt8] = []
    /// Split writes into chunks of 1 to 5 bytes, to exercise partial reads in the proxy.
    public var splitWrites = false
    private var buffer: [UInt8] = []
    private let lock = NSLock()

    public init(input: Int32, output: Int32) {
        self.input = input
        self.output = output
    }

    /// The server's reply to one command.
    public struct Reply: Sendable {
        /// Every line before the final one, without LF.
        public var lines: [[UInt8]]
        /// The final `OK …` or `ERR …` line, or nil at end of file.
        public var final: String?
        public var isOK: Bool { final?.hasPrefix("OK") == true }

        public var dataPayload: [UInt8] {
            lines.filter { $0.starts(with: Array("D ".utf8)) }.flatMap { Self.unescape($0.dropFirst(2)) }
        }

        public var statusLines: [String] {
            lines.filter { $0.starts(with: Array("S ".utf8)) }.map { String(decoding: $0, as: UTF8.self) }
        }

        static func unescape(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
            var out: [UInt8] = []
            var i = bytes.startIndex
            while i < bytes.endIndex {
                if bytes[i] == 0x25, i + 2 < bytes.endIndex,
                   let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    out.append(v)
                    i += 3
                } else {
                    out.append(bytes[i])
                    i += 1
                }
            }
            return out
        }
    }

    /// How the driver answers an inquiry: data to send as D lines then END, or nil to send CAN.
    public typealias InquiryHandler = @Sendable (_ keyword: String, _ line: [UInt8]) -> [UInt8]?

    /// The answer gpg-agent gives to NEEDPIN: the PIN padded with NUL bytes to 90 bytes.
    public static func pinAnswer(_ pin: String) -> [UInt8] {
        let bytes = Array(pin.utf8)
        return bytes + [UInt8](repeating: 0, count: max(0, 90 - bytes.count))
    }

    /// Answers NEEDPIN with `pin` (or cancels when nil) and PINCACHE_GET with `cachedPin` or an empty answer.
    public static func standardInquiries(pin: String?, cachedPin: String? = nil, echo: [UInt8] = []) -> InquiryHandler {
        { keyword, _ in
            switch keyword {
            case "NEEDPIN": pin.map(pinAnswer)
            case "PINCACHE_GET": cachedPin.map { Array($0.utf8) } ?? []
            case "ECHO": echo
            default: nil
            }
        }
    }

    /// Reads the server's greeting line.
    public func readHello() -> String? {
        readLine().map { String(decoding: $0, as: UTF8.self) }
    }

    /// Sends a command and reads lines until OK or ERR, answering inquiries with `inquiries`.
    public func transact(_ command: String, inquiries: InquiryHandler? = nil) -> Reply {
        transact(raw: Array(command.utf8) + [0x0A], inquiries: inquiries)
    }

    /// Sends raw bytes (which must end with LF) and reads the reply.
    public func transact(raw: [UInt8], inquiries: InquiryHandler? = nil) -> Reply {
        send(raw)
        var lines: [[UInt8]] = []
        while let line = readLine() {
            if line.starts(with: Array("OK".utf8)) || line.starts(with: Array("ERR".utf8)) {
                return Reply(lines: lines, final: String(decoding: line, as: UTF8.self))
            }
            if line.starts(with: Array("INQUIRE ".utf8)) {
                let rest = line.dropFirst(8)
                let keyword = String(decoding: rest.prefix { $0 != 0x20 }, as: UTF8.self)
                if let answer = inquiries?(keyword, line) {
                    sendData(answer)
                    send(Array("END\n".utf8))
                } else {
                    send(Array("CAN\n".utf8))
                }
                lines.append(line)
                continue
            }
            lines.append(line)
        }
        return Reply(lines: lines, final: nil)
    }

    /// Sends data as D lines, escaping only %, CR and LF, at most 1000 bytes per line, like libassuan.
    public func sendData(_ payload: [UInt8]) {
        var line: [UInt8] = Array("D ".utf8)
        for byte in payload {
            if byte == 0x25 || byte == 0x0D || byte == 0x0A {
                line += Array(String(format: "%%%02X", byte).utf8)
            } else {
                line.append(byte)
            }
            if line.count >= 998 {
                send(line + [0x0A])
                line = Array("D ".utf8)
            }
        }
        if line.count > 2 { send(line + [0x0A]) }
    }

    public func send(_ bytes: [UInt8]) {
        lock.lock()
        sent += bytes
        lock.unlock()
        if splitWrites {
            var i = 0
            while i < bytes.count {
                let n = min(bytes.count - i, 1 + i % 5)
                bytes[i..<(i + n)].withUnsafeBytes { _ = Posix.writeAll(output, $0) }
                i += n
            }
        } else {
            Posix.writeAll(output, bytes)
        }
    }

    /// Reads one line without its LF, or nil at end of file.
    public func readLine() -> [UInt8]? {
        while true {
            if let lf = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<lf])
                buffer.removeSubrange(...lf)
                return line
            }
            guard let chunk = readChunk() else { return nil }
            buffer += chunk
        }
    }

    /// Reads until end of file and returns whatever arrived after the last complete line read.
    public func readToEnd() -> [UInt8] {
        while let chunk = readChunk() { buffer += chunk }
        let rest = buffer
        buffer.removeAll()
        return rest
    }

    private func readChunk() -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = chunk.withUnsafeMutableBytes { Posix.read(input, $0) }
        guard n > 0 else { return nil }
        lock.lock()
        received += chunk[0..<n]
        lock.unlock()
        return Array(chunk[0..<n])
    }

    /// Closes the write side, as gpg-agent does when it releases the connection.
    public func closeOutput() {
        Posix.close(output)
    }
}
